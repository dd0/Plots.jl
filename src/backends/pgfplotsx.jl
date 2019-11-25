using Contour: Contour
Base.@kwdef mutable struct PGFPlotsXPlot
    is_created::Bool = false
    was_shown::Bool = false
    the_plot::PGFPlotsX.TikzDocument = PGFPlotsX.TikzDocument()
    function PGFPlotsXPlot(is_created, was_shown, the_plot)
        pgfx_plot = new(is_created, was_shown, the_plot)
        # tikz libraries
        PGFPlotsX.push_preamble!(pgfx_plot.the_plot, "\\usetikzlibrary{arrows.meta}")
        PGFPlotsX.push_preamble!(pgfx_plot.the_plot, "\\usetikzlibrary{backgrounds}")
        PGFPlotsX.push_preamble!(pgfx_plot.the_plot,
        """
        \\pgfkeys{/tikz/.cd,
          background color/.initial=white,
          background color/.get=\\backcol,
          background color/.store in=\\backcol,
        }
        \\tikzset{background rectangle/.style={
            fill=\\backcol,
          },
          use background/.style={
            show background rectangle
          }
        }
        """
        )
        # pgfplots libraries
        PGFPlotsX.push_preamble!(pgfx_plot.the_plot, "\\usepgfplotslibrary{patchplots}")
        PGFPlotsX.push_preamble!(pgfx_plot.the_plot, "\\usepgfplotslibrary{fillbetween}")
        pgfx_plot
    end
end

function pgfx_axes(pgfx_plot::PGFPlotsXPlot)
    gp =  pgfx_plot.the_plot.elements[1]
    return gp isa PGFPlotsX.GroupPlot ? gp.elements[1].contents : gp
end


function surface_to_vecs(x::AVec, y::AVec, s::Union{AMat, Surface})
    a = Array(s)
    xn = Vector{eltype(x)}(undef, length(a))
    yn = Vector{eltype(y)}(undef, length(a))
    zn = Vector{eltype(s)}(undef, length(a))
    for (n, (i, j)) in enumerate(Tuple.(CartesianIndices(a)))
        xn[n] = x[j]
        yn[n] = y[i]
        zn[n] = a[i,j]
    end
    return xn, yn, zn
end

Base.display(pgfx_plot::PGFPlotsXPlot) = display(pgfx_plot.the_plot)
function Base.show(io::IO, mime::MIME, pgfx_plot::PGFPlotsXPlot)
    show(io::IO, mime, pgfx_plot.the_plot)
end

function Base.push!(pgfx_plot::PGFPlotsXPlot, item)
    push!(pgfx_plot.the_plot, item)
end

function (pgfx_plot::PGFPlotsXPlot)(plt::Plot{PGFPlotsXBackend})
    if !pgfx_plot.is_created
        the_plot = PGFPlotsX.TikzPicture(PGFPlotsX.Options())
        cols, rows = size(plt.layout.grid)
        bgc = plt.attr[:background_color_outside]
        if bgc isa Colors.Colorant
            cstr = plot_color(bgc)
            a = alpha(cstr)
            push!(the_plot.options,
                "draw opacity" => a,
                "background color" => cstr,
                "use background" => nothing,
            )
        end

        # the combination of groupplot and polaraxis is broken in pgfplots
        if !any( sp -> ispolar(sp), plt.subplots )
            pl_height, pl_width = plt.attr[:size]
            push!( the_plot, PGFPlotsX.GroupPlot(
                    PGFPlotsX.Options(
                        "group style" => PGFPlotsX.Options(
                            "group size" => string(cols)*" by "*string(rows),
                            "horizontal sep" => string(maximum(sp -> sp.minpad[1], plt.subplots)),
                            "vertical sep" => string(maximum(sp -> sp.minpad[2], plt.subplots)),
                        ),
                    "height" => pl_height > 0 ? string(pl_height)*"px" : "{}",
                    "width" => pl_width > 0 ? string(pl_width)*"px" : "{}",
                    )
                )
            )
        end
        for sp in plt.subplots
            bb = bbox(sp)
            cstr = plot_color(sp[:background_color_legend])
            a = alpha(cstr)
            title_cstr = plot_color(sp[:titlefontcolor])
            title_a = alpha(cstr)
            axis_opt = PGFPlotsX.Options(
                "height" => string(height(bb)),
                "width" => string(width(bb)),
                "title" => sp[:title],
                "title style" => PGFPlotsX.Options(
                    "font" => pgfx_font(sp[:titlefontsize], pgfx_thickness_scaling(sp)),
                    "color" => title_cstr,
                    "draw opacity" => title_a,
                    "rotate" => sp[:titlefontrotation]
                ),
                "legend style" => PGFPlotsX.Options(
                    pgfx_linestyle(pgfx_thickness_scaling(sp), sp[:foreground_color_legend], 1.0, "solid") => nothing,
                    "fill" => cstr,
                    "font" => pgfx_font(sp[:legendfontsize], pgfx_thickness_scaling(sp))
                ),
                "axis background/.style" => PGFPlotsX.Options(
                    "fill" => sp[:background_color_inside]
                )
            )
            # legend position
            if sp[:legend] isa Tuple
                x, y = sp[:legend]
                push!(axis_opt["legend style"], "at={($x, $y)}" )
            else
                push!(axis_opt, "legend pos" => get(_pgfplotsx_legend_pos, sp[:legend], "outer north east"),
                )
            end
            for letter in (:x, :y, :z)
                if letter != :z || is3d(sp)
                    pgfx_axis!(axis_opt, sp, letter)
                end
            end
            # Search series for any gradient. In case one series uses a gradient set
           # the colorbar and colomap.
           # The reasoning behind doing this on the axis level is that pgfplots
           # colorbar seems to only works on axis level and needs the proper colormap for
           # correctly displaying it.
           # It's also possible to assign the colormap to the series itself but
           # then the colormap needs to be added twice, once for the axis and once for the
           # series.
           # As it is likely that all series within the same axis use the same
           # colormap this should not cause any problem.
           for series in series_list(sp)
               for col in (:markercolor, :fillcolor, :linecolor)
                   if typeof(series.plotattributes[col]) == ColorGradient
                        PGFPlotsX.push_preamble!(pgfx_plot.the_plot, """\\pgfplotsset{
                            colormap={plots$(sp.attr[:subplot_index])}{$(pgfx_colormap(series.plotattributes[col]))},
                        }""")
                        push!(axis_opt,
                            "colorbar" => nothing,
                            "colormap name" => "plots$(sp.attr[:subplot_index])",
                        )
                       # goto is needed to break out of col and series for
                       @goto colorbar_end
                   end
               end
           end
           @label colorbar_end

           push!(axis_opt, "colorbar style" => PGFPlotsX.Options(
           "title" => sp[:colorbar_title],
           "point meta max" => get_clims(sp)[2],
           "point meta min" => get_clims(sp)[1]
           )
           )
           if is3d(sp)
               azim, elev = sp[:camera]
               push!( axis_opt, "view" => (azim, elev) )
           end
           axisf = if sp[:projection] == :polar
               # push!(axis_opt, "xmin" => 90)
               # push!(axis_opt, "xmax" => 450)
               PGFPlotsX.PolarAxis
           else
               PGFPlotsX.Axis
           end
           axis = axisf(
           axis_opt
           )
           for (series_index, series) in enumerate(series_list(sp))
               opt = series.plotattributes
               st = series[:seriestype]
               series_opt = PGFPlotsX.Options(
               "color" => single_color(opt[:linecolor]),
               )
               if is3d(series) || st == :heatmap #|| isfilledcontour(series)
                   series_func = PGFPlotsX.Plot3
               else
                   series_func = PGFPlotsX.Plot
               end
               if series[:fillrange] !== nothing && !isfilledcontour(series)
                   push!(series_opt, "area legend" => nothing)
               end
               if st == :heatmap
                   push!(axis.options,
                   "view" => "{0}{90}",
                   "shader" => "flat corner",
                   )
               end
               # treat segments
               segments = if st in (:wireframe, :heatmap, :contour, :surface, :contour3d)
                   iter_segments(surface_to_vecs(series[:x], series[:y], series[:z])...)
               else
                   iter_segments(series)
               end
               segment_opt = PGFPlotsX.Options()
               for (i, rng) in enumerate(segments)
                   segment_opt = merge( segment_opt, pgfx_linestyle(opt, i) )
                   if opt[:markershape] != :none
                       marker = opt[:markershape]
                       if marker isa Shape
                           x = marker.x
                           y = marker.y
                           scale_factor = 0.025
                           mark_size = opt[:markersize] * scale_factor
                           path = join(["($(x[i] * mark_size), $(y[i] * mark_size))" for i in eachindex(x)], " -- ")
                           c = get_markercolor(series, i)
                           a = get_markeralpha(series, i)
                           PGFPlotsX.push_preamble!(pgfx_plot.the_plot,
                           """
                           \\pgfdeclareplotmark{PlotsShape$(series_index)}{
                           \\filldraw
                           $path;
                           }
                           """
                           )
                       end
                       segment_opt = merge( segment_opt, pgfx_marker(opt, i) )
                   end
                   if st == :shape ||
                       (series[:fillrange] !== nothing && !isfilledcontour(series)) &&
                       series[:ribbon] === nothing
                       segment_opt = merge( segment_opt, pgfx_fillstyle(opt, i) )
                   end
                   coordinates = pgfx_series_coordinates!( sp, series, segment_opt, opt, rng )
                   segment_plot = series_func(
                   merge(series_opt, segment_opt),
                   coordinates,
                   (series[:fillrange] !== nothing && !isfilledcontour(series) && series[:ribbon] === nothing) ? "\\closedcycle" : "{}"
                   )
                   push!(axis, segment_plot)
                   # add ribbons?
                   ribbon = series[:ribbon]
                   if ribbon !== nothing
                       pgfx_add_ribbons!( axis, series, segment_plot, series_func, series_index )
                   end
                   # add to legend?
                   if i == 1 && opt[:label] != "" && sp[:legend] != :none && should_add_to_legend(series)
                       push!( axis, PGFPlotsX.LegendEntry( opt[:label] )
                       )
                   end
                   # add series annotations
                   anns = series[:series_annotations]
                   for (xi,yi,str,fnt) in EachAnn(anns, series[:x], series[:y])
                       pgfx_add_annotation!(axis, xi, yi, PlotText(str, fnt), pgfx_thickness_scaling(series))
                   end
               end
               # add subplot annotations
               anns = sp.attr[:annotations]
               for (xi,yi,txt) in anns
                   pgfx_add_annotation!(axis, xi, yi, txt)
               end
           end
           if ispolar(sp)
               axes = the_plot
           else
               axes = the_plot.elements[1]
           end
           push!( axes, axis )
           if length(plt.o.the_plot.elements) > 0
               plt.o.the_plot.elements[1] = the_plot
           else
               push!(plt.o, the_plot)
           end
       end
        pgfx_plot.is_created = true
    end
end
## seriestype specifics
@inline function pgfx_series_coordinates!(sp, series, segment_opt, opt, rng)
    st = series[:seriestype]
    # function args
    args =  if st in (:contour, :contour3d)
        opt[:x], opt[:y], Array(opt[:z])'
    elseif st in (:heatmap, :surface, :wireframe)
            surface_to_vecs(opt[:x], opt[:y], opt[:z])
    elseif is3d(st)
        opt[:x], opt[:y], opt[:z]
    elseif st == :straightline
        straightline_data(series)
    elseif st == :shape
        shape_data(series)
    elseif ispolar(sp)
        theta, r = opt[:x], opt[:y]
        rad2deg.(theta), r
    else
        opt[:x], opt[:y]
    end
    seg_args = if st in (:contour, :contour3d)
            args
        else
            (arg[rng] for arg in args)
        end
    if opt[:quiver] !== nothing
        push!(segment_opt, "quiver" => PGFPlotsX.Options(
            "u" => "\\thisrow{u}",
            "v" => "\\thisrow{v}",
            pgfx_arrow(opt[:arrow]) => nothing
            ),
        )
        x, y = collect(seg_args)
        return PGFPlotsX.Table([:x => x, :y => y, :u => opt[:quiver][1], :v => opt[:quiver][2]])
    else
        if isfilledcontour(series)
            st = :filledcontour
        end
        pgfx_series_coordinates!(Val(st), segment_opt, opt, seg_args)
    end
end
function pgfx_series_coordinates!(st_val::Union{Val{:path}, Val{:path3d}, Val{:straightline}}, segment_opt, opt, args)
    return PGFPlotsX.Coordinates(args...)
end
function pgfx_series_coordinates!(st_val::Union{Val{:scatter}, Val{:scatter3d}}, segment_opt, opt, args)
    push!( segment_opt, "only marks" => nothing )
    return PGFPlotsX.Coordinates(args...)
end
function pgfx_series_coordinates!(st_val::Val{:heatmap}, segment_opt, opt, args)
    push!(segment_opt,
        "surf" => nothing,
        "mesh/rows" => length(opt[:x]),
        "mesh/cols" => length(opt[:y])
    )
    return PGFPlotsX.Table(args...)
end

function pgfx_series_coordinates!(st_val::Val{:steppre}, segment_opt, opt, args)
    push!( segment_opt, "const plot mark right" => nothing )
    return PGFPlotsX.Coordinates(args...)
end
function pgfx_series_coordinates!(st_val::Val{:stepmid}, segment_opt, opt, args)
    push!( segment_opt, "const plot mark mid" => nothing )
    return PGFPlotsX.Coordinates(args...)
end
function pgfx_series_coordinates!(st_val::Val{:steppost}, segment_opt, opt, args)
    push!( segment_opt, "const plot" => nothing )
    return PGFPlotsX.Coordinates(args...)
end
function pgfx_series_coordinates!(st_val::Union{Val{:ysticks},Val{:sticks}}, segment_opt, opt, args)
    push!( segment_opt, "ycomb" => nothing )
    return PGFPlotsX.Coordinates(args...)
end
function pgfx_series_coordinates!(st_val::Val{:xsticks}, segment_opt, opt, args)
    push!( segment_opt, "xcomb" => nothing )
    return PGFPlotsX.Coordinates(args...)
end
function pgfx_series_coordinates!(st_val::Val{:surface}, segment_opt, opt, args)
    push!( segment_opt, "surf" => nothing,
        "mesh/rows" => length(opt[:x]),
        "mesh/cols" => length(opt[:y]),
    )
    return PGFPlotsX.Coordinates(args...)
end
function pgfx_series_coordinates!(st_val::Val{:volume}, segment_opt, opt, args)
    push!( segment_opt, "patch" => nothing )
    return PGFPlotsX.Coordinates(args...)
end
function pgfx_series_coordinates!(st_val::Val{:wireframe}, segment_opt, opt, args)
    push!( segment_opt, "mesh" => nothing,
        "mesh/rows" => length(opt[:x])
    )
    return PGFPlotsX.Coordinates(args...)
end
function pgfx_series_coordinates!(st_val::Val{:shape}, segment_opt, opt, args)
    push!( segment_opt, "area legend" => nothing )
    return PGFPlotsX.Coordinates(args...)
end
function pgfx_series_coordinates!(st_val::Union{Val{:contour}, Val{:contour3d}}, segment_opt, opt, args)
    push!(segment_opt,
        "contour prepared" => PGFPlotsX.Options(
            "labels" => opt[:contour_labels],
        ),
    )
    return PGFPlotsX.Table(Contour.contours(args..., opt[:levels]))
end
function pgfx_series_coordinates!(st_val::Val{:filledcontour}, segment_opt, opt, args)
    xs, ys, zs = collect(args)
    push!(segment_opt,
        "contour filled" => PGFPlotsX.Options(
            "labels" => opt[:contour_labels],
        ),
        "point meta" => "explicit",
        "shader" => "flat"
    )
    if opt[:levels] isa Number
        push!(segment_opt["contour filled"],
            "number" => opt[:levels],
        )
    elseif opt[:levels] isa AVec
        push!(segment_opt["contour filled"],
            "levels" => opt[:levels],
        )
    end

    cs = join([
            join(["($x, $y) [$(zs[j, i])]" for (j, x) in enumerate(xs)], " ") for (i, y) in enumerate(ys)], "\n\n"
        )
    """
        coordinates {
        $cs
        };
    """
end
##
const _pgfplotsx_linestyles = KW(
    :solid => "solid",
    :dash => "dashed",
    :dot => "dotted",
    :dashdot => "dashdotted",
    :dashdotdot => "dashdotdotted",
)

const _pgfplotsx_markers = KW(
    :none => "none",
    :cross => "+",
    :xcross => "x",
    :+ => "+",
    :x => "x",
    :utriangle => "triangle*",
    :dtriangle => "triangle*",
    :rtriangle => "triangle*",
    :ltriangle => "triangle*",
    :circle => "*",
    :rect => "square*",
    :star5 => "star",
    :star6 => "asterisk",
    :diamond => "diamond*",
    :pentagon => "pentagon*",
    :hline => "-",
    :vline => "|"
)

const _pgfplotsx_legend_pos = KW(
    :bottomleft => "south west",
    :bottomright => "south east",
    :topright => "north east",
    :topleft => "north west",
    :outertopright => "outer north east",
)

const _pgfx_framestyles = [:box, :axes, :origin, :zerolines, :grid, :none]
const _pgfx_framestyle_defaults = Dict(:semi => :box)

# we use the anchors to define orientations for example to align left
# one needs to use the right edge as anchor
const _pgfx_annotation_halign = KW(
    :center => "",
    :left => "right",
    :right => "left"
)
## --------------------------------------------------------------------------------------
# Generates a colormap for pgfplots based on a ColorGradient
pgfx_arrow(::Nothing) = "every arrow/.append style={-}"
function pgfx_arrow( arr::Arrow )
    components = String[]
    head = String[]
    push!(head, "{stealth[length = $(arr.headlength)pt, width = $(arr.headwidth)pt")
    if arr.style == :open
        push!(head, ", open")
    end
    push!(head, "]}")
    head = join(head, "")
    if arr.side == :both || arr.side == :tail
        push!( components,  head )
    end
    push!(components, "-")
    if arr.side == :both || arr.side == :head
        push!( components, head )
    end
    components = join( components, "" )
    return "every arrow/.append style={$(components)}"
end

function pgfx_colormap(grad::ColorGradient)
    join(map(grad.colors) do c
        @sprintf("rgb=(%.8f,%.8f,%.8f)", red(c), green(c), blue(c))
    end,"\n")
end
function pgfx_colormap(grad::Vector{<:Colorant})
    join(map(grad) do c
        @sprintf("rgb=(%.8f,%.8f,%.8f)", red(c), green(c), blue(c))
    end,"\n")
end

function pgfx_framestyle(style::Symbol)
    if style in _pgfx_framestyles
        return style
    else
        default_style = get(_pgfx_framestyle_defaults, style, :axes)
        @warn("Framestyle :$style is not (yet) supported by the PGFPlots backend. :$default_style was cosen instead.")
        default_style
    end
end

pgfx_thickness_scaling(plt::Plot) = plt[:thickness_scaling]
pgfx_thickness_scaling(sp::Subplot) = pgfx_thickness_scaling(sp.plt)
pgfx_thickness_scaling(series) = pgfx_thickness_scaling(series[:subplot])

function pgfx_fillstyle(plotattributes, i = 1)
    cstr = get_fillcolor(plotattributes, i)
    a = get_fillalpha(plotattributes, i)
    if a === nothing
        a = alpha(single_color(cstr))
    end
    PGFPlotsX.Options("fill" => cstr, "fill opacity" => a)
end

function pgfx_linestyle(linewidth::Real, color, α = 1, linestyle = "solid")
    cstr = plot_color(color, α)
    a = alpha(cstr)
    return PGFPlotsX.Options(
        "color" => cstr,
        "draw opacity" => a,
        "line width" => linewidth,
        get(_pgfplotsx_linestyles, linestyle, "solid") => nothing
    )
end

function pgfx_linestyle(plotattributes, i = 1)
    lw = pgfx_thickness_scaling(plotattributes) * get_linewidth(plotattributes, i)
    lc = single_color(get_linecolor(plotattributes, i))
    la = get_linealpha(plotattributes, i)
    ls = get_linestyle(plotattributes, i)
    return pgfx_linestyle(lw, lc, la, ls)
end

function pgfx_font(fontsize, thickness_scaling = 1, font = "\\selectfont")
    fs = fontsize * thickness_scaling
    return string("{\\fontsize{", fs, " pt}{", 1.3fs, " pt}", font, "}")
end

function pgfx_marker(plotattributes, i = 1)
    shape = _cycle(plotattributes[:markershape], i)
    cstr = plot_color(get_markercolor(plotattributes, i), get_markeralpha(plotattributes, i))
    a = alpha(cstr)
    cstr_stroke = plot_color(get_markerstrokecolor(plotattributes, i), get_markerstrokealpha(plotattributes, i))
    a_stroke = alpha(cstr_stroke)
    mark_size = pgfx_thickness_scaling(plotattributes) * 0.5 * _cycle(plotattributes[:markersize], i)
    return PGFPlotsX.Options(
        "mark" => shape isa Shape ? "PlotsShape$i" : get(_pgfplotsx_markers, shape, "*"),
        "mark size" => "$mark_size pt",
        "mark options" => PGFPlotsX.Options(
            "color" => cstr_stroke,
            "draw opacity" => a_stroke,
            "fill" => cstr,
            "fill opacity" => a,
            "line width" => pgfx_thickness_scaling(plotattributes) * _cycle(plotattributes[:markerstrokewidth], i),
            "rotate" => if shape == :dtriangle
                            180
                        elseif shape == :rtriangle
                            270
                        elseif shape == :ltriangle
                            90
                        else
                            0
                        end,
            get(_pgfplotsx_linestyles, _cycle(plotattributes[:markerstrokestyle], i), "solid") => nothing
            )
    )
end

function pgfx_add_annotation!(o, x, y, val, thickness_scaling = 1)
    # Construct the style string.
    # Currently supports color and orientation
    cstr = val.font.color
    a = alpha(cstr)
    push!(o, ["\\node",
        PGFPlotsX.Options(
            get(_pgfx_annotation_halign,val.font.halign,"") => nothing,
            "color" => cstr,
            "draw opacity" => convert(Float16, a),
            "rotate" => val.font.rotation,
            "font" => pgfx_font(val.font.pointsize, thickness_scaling)
        ),
        " at ",
        PGFPlotsX.Coordinate(x, y),
        "{$(val.str).};"
    ])
end

function pgfx_add_ribbons!( axis, series, segment_plot, series_func, series_index )
    ribbon_y = series[:ribbon]
    opt = series.plotattributes
    if ribbon_y isa AVec
        ribbon_n = length(opt[:y]) ÷ length(ribbon)
        ribbon_y = repeat(ribbon, outer = ribbon_n)
    end
    # upper ribbon
    ribbon_name_plus = "plots_rib_p$series_index"
    ribbon_opt_plus = merge(segment_plot.options, PGFPlotsX.Options(
        "name path" => ribbon_name_plus,
        "color" => opt[:fillcolor],
        "draw opacity" => opt[:fillalpha]
    ))
    coordinates_plus = PGFPlotsX.Coordinates(opt[:x], opt[:y] .+ ribbon_y)
    ribbon_plot_plus = series_func(
        ribbon_opt_plus,
        coordinates_plus
    )
    push!(axis, ribbon_plot_plus)
    # lower ribbon
    ribbon_name_minus = "plots_rib_m$series_index"
    ribbon_opt_minus = merge(segment_plot.options, PGFPlotsX.Options(
        "name path" => ribbon_name_minus,
        "color" => opt[:fillcolor],
        "draw opacity" => opt[:fillalpha]
    ))
    coordinates_plus = PGFPlotsX.Coordinates(opt[:x], opt[:y] .- ribbon_y)
    ribbon_plot_plus = series_func(
        ribbon_opt_minus,
        coordinates_plus
    )
    push!(axis, ribbon_plot_plus)
    # fill
    push!(axis, series_func(
        pgfx_fillstyle(opt, series_index),
        "fill between [of=$(ribbon_name_plus) and $(ribbon_name_minus)]"
    ))
    return axis
end
# --------------------------------------------------------------------------------------
function pgfx_axis!(opt::PGFPlotsX.Options, sp::Subplot, letter)
    axis = sp[Symbol(letter,:axis)]

    # turn off scaled ticks
    push!(opt, "scaled $(letter) ticks" => "false",
        string(letter,:label) => axis[:guide],
    )

    # set to supported framestyle
    framestyle = pgfx_framestyle(sp[:framestyle])

    # axis label position
    labelpos = ""
    if letter == :x && axis[:guide_position] == :top
        labelpos = "at={(0.5,1)},above,"
    elseif letter == :y && axis[:guide_position] == :right
        labelpos = "at={(1,0.5)},below,"
    end

    # Add label font
    cstr = plot_color(axis[:guidefontcolor])
    α = alpha(cstr)
    push!(opt, string(letter, "label style") => PGFPlotsX.Options(
        labelpos => nothing,
        "font" => pgfx_font(axis[:guidefontsize], pgfx_thickness_scaling(sp)),
        "color" => cstr,
        "draw opacity" => α,
        "rotate" => axis[:guidefontrotation],
        )
    )

    # flip/reverse?
    axis[:flip] && push!(opt, "$letter dir" => "reverse")

    # scale
    scale = axis[:scale]
    if scale in (:log2, :ln, :log10)
        push!(opt, string(letter,:mode) => "log")
        scale == :ln || push!(opt, "log basis $letter" => "$(scale == :log2 ? 2 : 10)")
    end

    # ticks on or off
    if axis[:ticks] in (nothing, false, :none) || framestyle == :none
        push!(opt, "$(letter)majorticks" => "false")
    end

    # grid on or off
    if axis[:grid] && framestyle != :none
        push!(opt, "$(letter)majorgrids" => "true")
    else
        push!(opt, "$(letter)majorgrids" => "false")
    end

    # limits
    lims = ispolar(sp) && letter == :x ? rad2deg.(axis_limits(sp, :x)) : axis_limits(sp, letter)
    push!( opt,
        string(letter,:min) => lims[1],
        string(letter,:max) => lims[2]
    )

    if !(axis[:ticks] in (nothing, false, :none, :native)) && framestyle != :none
        ticks = get_ticks(sp, axis)
        #pgf plot ignores ticks with angle below 90 when xmin = 90 so shift values
        tick_values = ispolar(sp) && letter == :x ? [rad2deg.(ticks[1])[3:end]..., 360, 405] : ticks[1]
        push!(opt, string(letter, "tick") => string("{", join(tick_values,","), "}"))
        if axis[:showaxis] && axis[:scale] in (:ln, :log2, :log10) && axis[:ticks] == :auto
            # wrap the power part of label with }
            tick_labels = Vector{String}(undef, length(ticks[2]))
            for (i, label) in enumerate(ticks[2])
                base, power = split(label, "^")
                power = string("{", power, "}")
                tick_labels[i] = string(base, "^", power)
            end
            push!(opt, string(letter, "ticklabels") => string("{\$", join(tick_labels,"\$,\$"), "\$}"))
        elseif axis[:showaxis]
            tick_labels = ispolar(sp) && letter == :x ? [ticks[2][3:end]..., "0", "45"] : ticks[2]
            if axis[:formatter] in (:scientific, :auto)
                tick_labels = string.("\$", convert_sci_unicode.(tick_labels), "\$")
                tick_labels = replace.(tick_labels, Ref("×" => "\\times"))
            end
            push!(opt, string(letter, "ticklabels") => string("{", join(tick_labels,","), "}"))
        else
            push!(opt, string(letter, "ticklabels") => "{}")
        end
        push!(opt, string(letter, "tick align") => (axis[:tick_direction] == :out ? "outside" : "inside"))
        cstr = plot_color(axis[:tickfontcolor])
        α = alpha(cstr)
        push!(opt, string(letter, "ticklabel style") => PGFPlotsX.Options(
                "font" => pgfx_font(axis[:tickfontsize], pgfx_thickness_scaling(sp)),
                "color" => cstr,
                "draw opacity" => α,
                "rotate" => axis[:tickfontrotation]
            )
        )
        push!(opt, string(letter, " grid style") => pgfx_linestyle(pgfx_thickness_scaling(sp) * axis[:gridlinewidth], axis[:foreground_color_grid], axis[:gridalpha], axis[:gridstyle])
        )
    end

    # framestyle
    if framestyle in (:axes, :origin)
        axispos = framestyle == :axes ? "left" : "middle"
        if axis[:draw_arrow]
            push!(opt, string("axis ", letter, " line") => axispos)
        else
            # the * after line disables the arrow at the axis
            push!(opt, string("axis ", letter, " line*") => axispos)
        end
    end

    if framestyle == :zerolines
        push!(opt, string("extra ", letter, " ticks") => "0")
        push!(opt, string("extra ", letter, " tick labels") => "")
        push!(opt, string("extra ", letter, " tick style") => PGFPlotsX.Options(
                "grid" => "major",
                "major grid style" => pgfx_linestyle(pgfx_thickness_scaling(sp), axis[:foreground_color_border], 1.0)
            )
        )
    end

    if !axis[:showaxis]
        push!(opt, "separate axis lines")
    end
    if !axis[:showaxis] || framestyle in (:zerolines, :grid, :none)
        push!(opt, string(letter, " axis line style") => "{draw opacity = 0}")
    else
        push!(opt, string(letter, " axis line style") => pgfx_linestyle(pgfx_thickness_scaling(sp), axis[:foreground_color_border], 1.0)
        )
    end
end
# --------------------------------------------------------------------------------------
# display calls this and then _display, its called 3 times for plot(1:5)
# Set the (left, top, right, bottom) minimum padding around the plot area
# to fit ticks, tick labels, guides, colorbars, etc.
function _update_min_padding!(sp::Subplot{PGFPlotsXBackend})
    # TODO: make padding more intelligent
    # order: right, top, left, bottom
    sp.minpad = (22mm, 12mm, 2mm, 10mm)
end

function _create_backend_figure(plt::Plot{PGFPlotsXBackend})
    plt.o = PGFPlotsXPlot()
end

function _series_added(plt::Plot{PGFPlotsXBackend}, series::Series)
    plt.o.is_created = false
end

function _update_plot_object(plt::Plot{PGFPlotsXBackend})
    plt.o(plt)
end

function _show(io::IO, mime::MIME"image/svg+xml", plt::Plot{PGFPlotsXBackend})
    _update_plot_object(plt)
    show(io, mime, plt.o)
end

function _show(io::IO, mime::MIME"application/pdf", plt::Plot{PGFPlotsXBackend})
    _update_plot_object(plt)
    show(io, mime, plt.o)
end

function _show(io::IO, mime::MIME"image/png", plt::Plot{PGFPlotsXBackend})
    _update_plot_object(plt)
    show(io, mime, plt.o)
end

function _show(io::IO, mime::MIME"application/x-tex", plt::Plot{PGFPlotsXBackend})
    _update_plot_object(plt)
    PGFPlotsX.print_tex(io, plt.o.the_plot)
end

function _display(plt::Plot{PGFPlotsXBackend})
    plt.o
end
