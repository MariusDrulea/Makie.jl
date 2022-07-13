# This file was generated, do not modify it. # hide
__result = begin # hide
    using CairoMakie
CairoMakie.activate!() # hide
Makie.inline!(true) # hide

fig, ax, p = scatter(Point2f(0), marker = 'x', markersize = 20)
tooltip!(Point2f(0), "This is a tooltip pointing at x")
fig
end # hide
save(joinpath(@OUTPUT, "example_882546583911341605.png"), __result; ) # hide
save(joinpath(@OUTPUT, "example_882546583911341605.svg"), __result; ) # hide
nothing # hide