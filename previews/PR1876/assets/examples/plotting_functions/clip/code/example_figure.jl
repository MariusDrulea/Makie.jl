# This file was generated, do not modify it. # hide
__result = begin # hide
    using CairoMakie
CairoMakie.activate!() # hide
Makie.inline!(true) # hide

fig = Figure()
ax = Axis(fig[1, 1])
clip!(ax, Circle(Point2f(5), 3))

plt = heatmap(rand(10, 10))

fig
end # hide
save(joinpath(@OUTPUT, "example_6134269372543893382.png"), __result) # hide

nothing # hide