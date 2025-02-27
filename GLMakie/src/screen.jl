const ScreenID = UInt8
const ZIndex = Int
# ID, Area, clear, is visible, background color
const ScreenArea = Tuple{ScreenID, Scene}

abstract type GLScreen <: AbstractScreen end

mutable struct Screen <: GLScreen
    glscreen::GLFW.Window
    shader_cache::GLAbstraction.ShaderCache
    framebuffer::GLFramebuffer
    rendertask::RefValue{Task}
    screen2scene::Dict{WeakRef, ScreenID}
    screens::Vector{ScreenArea}
    renderlist::Vector{Tuple{ZIndex, ScreenID, RenderObject}}
    postprocessors::Vector{PostProcessor}
    cache::Dict{UInt64, RenderObject}
    cache2plot::Dict{UInt32, AbstractPlot}
    framecache::Matrix{RGB{N0f8}}
    render_tick::Observable{Nothing}
    window_open::Observable{Bool}

    function Screen(
            glscreen::GLFW.Window,
            shader_cache::GLAbstraction.ShaderCache,
            framebuffer::GLFramebuffer,
            rendertask::RefValue{Task},
            screen2scene::Dict{WeakRef, ScreenID},
            screens::Vector{ScreenArea},
            renderlist::Vector{Tuple{ZIndex, ScreenID, RenderObject}},
            postprocessors::Vector{PostProcessor},
            cache::Dict{UInt64, RenderObject},
            cache2plot::Dict{UInt32, AbstractPlot},
        )
        s = size(framebuffer)
        return new(
            glscreen, shader_cache, framebuffer, rendertask, screen2scene,
            screens, renderlist, postprocessors, cache, cache2plot,
            Matrix{RGB{N0f8}}(undef, s), Observable(nothing),
            Observable(true)
        )
    end
end

GeometryBasics.widths(x::Screen) = size(x.framebuffer)
pollevents(::GLScreen) = nothing
function pollevents(screen::Screen)
    ShaderAbstractions.switch_context!(screen.glscreen)
    notify(screen.render_tick)
    GLFW.PollEvents()
end
Base.wait(x::Screen) = isassigned(x.rendertask) && wait(x.rendertask[])
Base.wait(scene::Scene) = wait(Makie.getscreen(scene))
Base.show(io::IO, screen::Screen) = print(io, "GLMakie.Screen(...)")
Base.size(x::Screen) = size(x.framebuffer)

function Makie.insertplots!(screen::GLScreen, scene::Scene)
    ShaderAbstractions.switch_context!(screen.glscreen)
    get!(screen.screen2scene, WeakRef(scene)) do
        id = length(screen.screens) + 1
        push!(screen.screens, (id, scene))
        return id
    end
    for elem in scene.plots
        insert!(screen, scene, elem)
    end
    foreach(s-> insertplots!(screen, s), scene.children)
end

function Base.delete!(screen::Screen, scene::Scene)
    for child in scene.children
        delete!(screen, child)
    end
    for plot in scene.plots
        delete!(screen, scene, plot)
    end

    if haskey(screen.screen2scene, WeakRef(scene))
        deleted_id = pop!(screen.screen2scene, WeakRef(scene))

        # TODO: this should always find something but sometimes doesn't...
        i = findfirst(id_scene -> id_scene[1] == deleted_id, screen.screens)
        i !== nothing && deleteat!(screen.screens, i)

        # Remap scene IDs to a continuous range by replacing the largest ID
        # with the one that got removed
        if deleted_id-1 != length(screen.screens)
            key, max_id = first(screen.screen2scene)
            for p in screen.screen2scene
                if p[2] > max_id
                    key, max_id = p
                end
            end

            i = findfirst(id_scene -> id_scene[1] == max_id, screen.screens)::Int
            screen.screens[i] = (deleted_id, screen.screens[i][2])

            screen.screen2scene[key] = deleted_id

            for (i, (z, id, robj)) in enumerate(screen.renderlist)
                if id == max_id
                    screen.renderlist[i] = (z, deleted_id, robj)
                end
            end
        end
    end

    return
end

function Base.delete!(screen::Screen, scene::Scene, plot::AbstractPlot)
    if !isempty(plot.plots)
        # this plot consists of children, so we flatten it and delete the children instead
        for cplot in Makie.flatten_plots(plot)
            delete!(screen, scene, cplot)
        end
    else
        renderobject = get(screen.cache, objectid(plot)) do
            error("Could not find $(typeof(subplot)) in current GLMakie screen!")
        end

        # These need explicit clean up because (some of) the source observables
        # remain whe the plot is deleated.
        for k in (:normalmatrix, )
            if haskey(renderobject.uniforms, k)
                n = renderobject.uniforms[k]
                for input in n.inputs
                    off(input)
                end
            end
        end
        filter!(x-> x[3] !== renderobject, screen.renderlist)
    end
end

function Base.empty!(screen::Screen)
    empty!(screen.render_tick.listeners)
    empty!(screen.window_open.listeners)
    empty!(screen.renderlist)
    empty!(screen.screen2scene)
    empty!(screen.screens)
    empty!(screen.cache)
    empty!(screen.cache2plot)
end

const GLFW_WINDOWS = GLFW.Window[]

const SINGLETON_SCREEN = Screen[]
const SINGLETON_SCREEN_NO_RENDERLOOP = Screen[]

function singleton_screen(resolution; visible=Makie.use_display[], start_renderloop=true)
    screen_ref = if start_renderloop
        SINGLETON_SCREEN
    else
        SINGLETON_SCREEN_NO_RENDERLOOP
    end

    if length(screen_ref) == 1 && isopen(screen_ref[1])
        screen = screen_ref[1]
        resize!(screen, resolution...)
        return screen
    else
        if !isempty(screen_ref)
            closeall(screen_ref)
        end
        screen = Screen(; resolution=resolution, visible=visible, start_renderloop=start_renderloop)
        push!(screen_ref, screen)
        return screen
    end
end

function destroy!(screen::Screen)
    screen.window_open[] = false
    empty!(screen)
    filter!(win -> win != screen.glscreen, GLFW_WINDOWS)
    destroy!(screen.glscreen)
end

Base.close(screen::Screen) = destroy!(screen)
function closeall(windows=GLFW_WINDOWS)
    if !isempty(windows)
        for elem in windows
            isopen(elem) && destroy!(elem)
        end
        empty!(windows)
    end
end

function resize_native!(window::GLFW.Window, resolution...)
    if isopen(window)
        ShaderAbstractions.switch_context!(window)
        oldsize = windowsize(window)
        retina_scale = retina_scaling_factor(window)
        w, h = resolution ./ retina_scale
        if oldsize == (w, h)
            return
        end
        GLFW.SetWindowSize(window, round(Int, w), round(Int, h))
    end
end

function Base.resize!(screen::Screen, w, h)
    nw = to_native(screen)
    resize_native!(nw, w, h)
    fb = screen.framebuffer
    resize!(fb, (w, h))
end

function fast_color_data!(dest::Array{RGB{N0f8}, 2}, source::Texture{T, 2}) where T
    GLAbstraction.bind(source)
    glPixelStorei(GL_PACK_ALIGNMENT, 1)
    glGetTexImage(source.texturetype, 0, GL_RGB, GL_UNSIGNED_BYTE, dest)
    GLAbstraction.bind(source, 0)
    nothing
end

"""
depthbuffer(screen::Screen)
Gets the depth buffer of screen.
Usage:
```
using Makie, GLMakie
x = scatter(1:4)
screen = display(x)
depth_color = GLMakie.depthbuffer(screen)
# Look at result:
heatmap(depth_color, colormap=:grays)
```
"""
function depthbuffer(screen::Screen)
    ShaderAbstractions.switch_context!(screen.glscreen)
    render_frame(screen, resize_buffers=false) # let it render
    glFinish() # block until opengl is done rendering
    source = screen.framebuffer.buffers[:depth]
    depth = Matrix{Float32}(undef, size(source))
    GLAbstraction.bind(source)
    GLAbstraction.glGetTexImage(source.texturetype, 0, GL_DEPTH_COMPONENT, GL_FLOAT, depth)
    GLAbstraction.bind(source, 0)
    return depth
end

function Makie.colorbuffer(screen::Screen, format::Makie.ImageStorageFormat = Makie.JuliaNative)
    if !isopen(screen)
        error("Screen not open!")
    end
    ShaderAbstractions.switch_context!(screen.glscreen)
    ctex = screen.framebuffer.buffers[:color]
    # polling may change window size, when its bigger than monitor!
    # we still need to poll though, to get all the newest events!
    # GLFW.PollEvents()
    # keep current buffer size to allows larger-than-window renders
    render_frame(screen, resize_buffers=false) # let it render
    glFinish() # block until opengl is done rendering
    if size(ctex) != size(screen.framecache)
        screen.framecache = Matrix{RGB{N0f8}}(undef, size(ctex))
    end
    fast_color_data!(screen.framecache, ctex)
    if format == Makie.GLNative
        return screen.framecache
    elseif format == Makie.JuliaNative
        @static if VERSION < v"1.6"
            bufc = copy(screen.framecache)
            ind1, ind2 = axes(bufc)
            n = first(ind2) + last(ind2)
            for i in ind1
                @simd for j in ind2
                    @inbounds bufc[i, n-j] = screen.framecache[i, j]
                end
            end
            screen.framecache = bufc
        else
            reverse!(screen.framecache, dims = 2)
        end
        return PermutedDimsArray(screen.framecache, (2,1))
    end
end


Base.isopen(x::Screen) = isopen(x.glscreen)
function Base.push!(screen::GLScreen, scene::Scene, robj)
    # filter out gc'ed elements
    filter!(screen.screen2scene) do (k, v)
        k.value !== nothing
    end
    screenid = get!(screen.screen2scene, WeakRef(scene)) do
        id = length(screen.screens) + 1
        push!(screen.screens, (id, scene))
        return id
    end
    push!(screen.renderlist, (0, screenid, robj))
    return robj
end

Makie.to_native(x::Screen) = x.glscreen

"""
OpenGL shares all data containers between shared contexts, but not vertexarrays -.-
So to share a robjs between a context, we need to rewrap the vertexarray into a new one for that
specific context.
"""
function rewrap(robj::RenderObject{Pre}) where Pre
    RenderObject{Pre}(
        robj.main,
        robj.uniforms,
        GLVertexArray(robj.vertexarray),
        robj.prerenderfunction,
        robj.postrenderfunction,
        robj.boundingbox,
    )
end

"""
Loads the makie loading icon and embedds it in an image the size of resolution
"""
function get_loading_image(resolution)
    icon = Matrix{N0f8}(undef, 192, 192)
    open(joinpath(@__DIR__, "..", "assets", "loading.bin")) do io
        read!(io, icon)
    end
    img = zeros(RGBA{N0f8}, resolution...)
    center = resolution .÷ 2
    center_icon = size(icon) .÷ 2
    start = CartesianIndex(max.(center .- center_icon, 1))
    I1 = CartesianIndex(1, 1)
    stop = min(start + CartesianIndex(size(icon)) - I1, CartesianIndex(resolution))
    for idx in start:stop
        gray = icon[idx - start + I1]
        img[idx] = RGBA{N0f8}(gray, gray, gray, 1.0)
    end
    return img
end

function display_loading_image(screen::Screen)
    fb = screen.framebuffer
    fbsize = size(fb)
    image = get_loading_image(fbsize)
    if size(image) == fbsize
        nw = to_native(screen)
        # transfer loading image to gpu framebuffer
        fb.buffers[:color][1:size(image, 1), 1:size(image, 2)] = image
        ShaderAbstractions.is_context_active(nw) || return
        w, h = fbsize
        glBindFramebuffer(GL_FRAMEBUFFER, 0) # transfer back to window
        glViewport(0, 0, w, h)
        glClearColor(0, 0, 0, 0)
        glClear(GL_COLOR_BUFFER_BIT)
        # GLAbstraction.render(fb.postprocess[end]) # copy postprocess
        GLAbstraction.render(screen.postprocessors[end].robjs[1])
        GLFW.SwapBuffers(nw)
    else
        error("loading_image needs to be Matrix{RGBA{N0f8}} with size(loading_image) == resolution")
    end
end


function Screen(;
        resolution = (10, 10), visible = true, title = WINDOW_CONFIG.title[],
        start_renderloop = true,
        kw_args...
    )
    # Somehow this constant isn't wrapped by glfw
    GLFW_FOCUS_ON_SHOW = 0x0002000C
    windowhints = [
        (GLFW.SAMPLES,      0),
        (GLFW.DEPTH_BITS,   0),

        # SETTING THE ALPHA BIT IS REALLY IMPORTANT ON OSX, SINCE IT WILL JUST KEEP SHOWING A BLACK SCREEN
        # WITHOUT ANY ERROR -.-
        (GLFW.ALPHA_BITS,   8),
        (GLFW.RED_BITS,     8),
        (GLFW.GREEN_BITS,   8),
        (GLFW.BLUE_BITS,    8),

        (GLFW.STENCIL_BITS, 0),
        (GLFW.AUX_BUFFERS,  0),
        (GLFW_FOCUS_ON_SHOW, WINDOW_CONFIG.focus_on_show[]),
        (GLFW.DECORATED, WINDOW_CONFIG.decorated[]),
        (GLFW.FLOATING, WINDOW_CONFIG.float[]),
        # (GLFW.TRANSPARENT_FRAMEBUFFER, true)
    ]

    window = try
        GLFW.Window(
            name = title, resolution = resolution,
            windowhints = windowhints,
            visible = false,
            focus = false,
            kw_args...
        )
    catch e
        @warn("""
            GLFW couldn't create an OpenGL window.
            This likely means, you don't have an OpenGL capable Graphic Card,
            or you don't have an OpenGL 3.3 capable video driver installed.
            Have a look at the troubleshooting section in the GLMakie readme:
            https://github.com/JuliaPlots/Makie.jl/tree/master/GLMakie#troubleshooting-opengl.
        """)
        rethrow(e)
    end

    GLFW.SetWindowIcon(window, Makie.icon())

    # tell GLAbstraction that we created a new context.
    # This is important for resource tracking, and only needed for the first context
    ShaderAbstractions.switch_context!(window)
    shader_cache = GLAbstraction.ShaderCache()
    push!(GLFW_WINDOWS, window)

    resize_native!(window, resolution...)

    fb = GLFramebuffer(resolution)

    postprocessors = [
        enable_SSAO[] ? ssao_postprocessor(fb, shader_cache) : empty_postprocessor(),
        OIT_postprocessor(fb, shader_cache),
        enable_FXAA[] ? fxaa_postprocessor(fb, shader_cache) : empty_postprocessor(),
        to_screen_postprocessor(fb, shader_cache)
    ]

    screen = Screen(
        window, shader_cache, fb,
        RefValue{Task}(),
        Dict{WeakRef, ScreenID}(),
        ScreenArea[],
        Tuple{ZIndex, ScreenID, RenderObject}[],
        postprocessors,
        Dict{UInt64, RenderObject}(),
        Dict{UInt32, AbstractPlot}(),
    )

    GLFW.SetWindowRefreshCallback(window, window -> refreshwindowcb(window, screen))
    if start_renderloop
        screen.rendertask[] = @async((WINDOW_CONFIG.renderloop[])(screen))
    end
    # display window if visible!
    if visible
        GLFW.ShowWindow(window)
    else
        GLFW.HideWindow(window)
    end
    return screen
end

function Screen(f, resolution)
    screen = Screen(resolution = resolution, visible = false, start_renderloop=false)
    try
        return f(screen)
    finally
        destroy!(screen)
    end
end


function refreshwindowcb(window, screen)
    ShaderAbstractions.switch_context!(screen.glscreen)
    screen.render_tick[] = nothing
    render_frame(screen)
    GLFW.SwapBuffers(window)
    return
end
