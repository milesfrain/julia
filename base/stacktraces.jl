# This file is a part of Julia. License is MIT: https://julialang.org/license

"""
Tools for collecting and manipulating stack traces. Mainly used for building errors.
"""
module StackTraces


import Base: hash, ==, show
import Core: CodeInfo, MethodInstance
using Base.Printf: @printf
using Base: something

export StackTrace, StackFrame, stacktrace

"""
    StackFrame

Stack information representing execution context, with the following fields:

- `func::Symbol`

  The name of the function containing the execution context.

- `linfo::Union{Core.MethodInstance, CodeInfo, Nothing}`

  The MethodInstance containing the execution context (if it could be found).

- `file::Symbol`

  The path to the file containing the execution context.

- `line::Int`

  The line number in the file containing the execution context.

- `from_c::Bool`

  True if the code is from C.

- `inlined::Bool`

  True if the code is from an inlined frame.

- `pointer::UInt64`

  Representation of the pointer to the execution context as returned by `backtrace`.

"""
struct StackFrame # this type should be kept platform-agnostic so that profiles can be dumped on one machine and read on another
    "the name of the function containing the execution context"
    func::Symbol
    "the path to the file containing the execution context"
    file::Symbol
    "the line number in the file containing the execution context"
    line::Int
    "the MethodInstance or CodeInfo containing the execution context (if it could be found)"
    linfo::Union{MethodInstance, CodeInfo, Nothing}
    "true if the code is from C"
    from_c::Bool
    "true if the code is from an inlined frame"
    inlined::Bool
    "representation of the pointer to the execution context as returned by `backtrace`"
    pointer::UInt64  # Large enough to be read losslessly on 32- and 64-bit machines.
end

StackFrame(func, file, line) = StackFrame(Symbol(func), Symbol(file), line,
                                          nothing, false, false, 0)

"""
    StackTrace

An alias for `Vector{StackFrame}` provided for convenience; returned by calls to
`stacktrace`.
"""
const StackTrace = Vector{StackFrame}

const empty_sym = Symbol("")
const UNKNOWN = StackFrame(empty_sym, empty_sym, -1, nothing, true, false, 0) # === lookup(C_NULL)


#=
If the StackFrame has function and line information, we consider two of them the same if
they share the same function/line information.
=#
function ==(a::StackFrame, b::StackFrame)
    return a.line == b.line && a.from_c == b.from_c && a.func == b.func && a.file == b.file && a.inlined == b.inlined # excluding linfo and pointer
end

function hash(frame::StackFrame, h::UInt)
    h += 0xf4fbda67fe20ce88 % UInt
    h = hash(frame.line, h)
    h = hash(frame.file, h)
    h = hash(frame.func, h)
    h = hash(frame.from_c, h)
    h = hash(frame.inlined, h)
    return h
end

"""
Classify stack frame according to heuristic importance level

Importance level 0 is intended to be the default minimum which will be shown to
users in stack traces.
"""
function frame_importance(frame::StackFrame)
    if frame.from_c
        return -2
    end
    mod = nothing
    if frame.linfo isa Core.MethodInstance
        def = frame.linfo.def
        if def isa Method
            is_hidden = ccall(:jl_ast_flag_hide_in_stacktrace, Bool, (Any,), def.source)
            if is_hidden
                # This overrides the module heuristic information
                return -1
            end
            mod = def.module
        elseif def isa Module
            # Top-level thunk ? (TODO: test this!)
            mod = def
        end
    elseif frame.linfo isa CodeInfo
        # mod = frame.linfo  # TODO: Test this
    end
    if mod !== nothing
        modroot = Base.moduleroot(mod)
        # TODO: Should Core be negative by default ?
        if modroot == Base || modroot == Core
            return 0
        elseif modroot == Main
            return 3
        # elseif ???
            # TODO: How can users customize this? For example can we return 2
            # for dev'd or unregistered modules?
            # return 2
        else
            return 1
        end
    end
    return 0
end

"""
    lookup(pointer::Union{Ptr{Cvoid}, UInt}) -> Vector{StackFrame}

Given a pointer to an execution context (usually generated by a call to `backtrace`), looks
up stack frame context information. Returns an array of frame information for all functions
inlined at that point, innermost function first.
"""
function lookup(pointer::Ptr{Cvoid})
    infos = ccall(:jl_lookup_code_address, Any, (Ptr{Cvoid}, Cint), pointer - 1, false)
    isempty(infos) && return [StackFrame(empty_sym, empty_sym, -1, nothing, true, false, convert(UInt64, pointer))]
    res = Vector{StackFrame}(undef, length(infos))
    for i in 1:length(infos)
        info = infos[i]
        @assert(length(info) == 7)
        res[i] = StackFrame(info[1], info[2], info[3], info[4], info[5], info[6], info[7])
    end
    return res
end

lookup(pointer::UInt) = lookup(convert(Ptr{Cvoid}, pointer))

const top_level_scope_sym = Symbol("top-level scope")

using Base.Meta
is_loc_meta(expr, kind) = isexpr(expr, :meta) && length(expr.args) >= 1 && expr.args[1] === kind
function lookup(ip::Base.InterpreterIP)
    if ip.code isa MethodInstance && ip.code.def isa Method
        codeinfo = ip.code.uninferred
        func = ip.code.def.name
        file = ip.code.def.file
        line = ip.code.def.line
    elseif ip.code === nothing
        # interpreted top-level expression with no CodeInfo
        return [StackFrame(top_level_scope_sym, empty_sym, 0, nothing, false, false, 0)]
    else
        @assert ip.code isa CodeInfo
        codeinfo = ip.code
        func = top_level_scope_sym
        file = empty_sym
        line = 0
    end
    i = max(ip.stmt+1, 1)  # ip.stmt is 0-indexed
    if i > length(codeinfo.codelocs) || codeinfo.codelocs[i] == 0
        return [StackFrame(func, file, line, ip.code, false, false, 0)]
    end
    lineinfo = codeinfo.linetable[codeinfo.codelocs[i]]
    scopes = StackFrame[]
    while true
        push!(scopes, StackFrame(lineinfo.method, lineinfo.file, lineinfo.line, ip.code, false, false, 0))
        if lineinfo.inlined_at == 0
            break
        end
        lineinfo = codeinfo.linetable[lineinfo.inlined_at]
    end
    return scopes
end

# allow lookup on already-looked-up data for easier handling of pre-processed frames
lookup(s::StackFrame) = StackFrame[s]
lookup(s::Tuple{StackFrame,Int}) = StackFrame[s[1]]

"""
    backtrace()

Get a backtrace object for the current program point.
"""
Base.@hide_in_stacktrace function Base.backtrace()
    bt1, bt2 = ccall(:jl_backtrace_from_here, Any, (Int32,), false)
    bt = Base._reformat_bt(bt1, bt2)
    if length(bt) > 2
        # remove frames for jl_backtrace_from_here and backtrace()
        @static if Base.Sys.iswindows() && Int === Int32
            # Note: win32 is missing the top frame
            # (see https://bugs.chromium.org/p/crashpad/issues/detail?id=53)
            deleteat!(bt, 1)
        else
            deleteat!(bt, 1:2)
        end
    end
    bt
end

"""
    stacktrace([trace::Vector{Ptr{Cvoid}},] [c_funcs::Bool=false]) -> StackTrace

Returns a stack trace in the form of a vector of `StackFrame`s. (By default stacktrace
doesn't return C functions, but this can be enabled.) When called without specifying a
trace, `stacktrace` first calls `backtrace`.
"""
function stacktrace(trace::Vector{<:Union{Base.InterpreterIP,Ptr{Cvoid}}}, c_funcs::Bool=false)
    stack = vcat(StackTrace(), map(lookup, trace)...)::StackTrace

    # Remove frames that come from C calls.
    if !c_funcs
        filter!(frame -> !frame.from_c, stack)
    end

    # is there a better way?  the func symbol has a number suffix which changes.
    # it's possible that no test is needed and we could just popfirst! all the time.
    # this line was added to PR #16213 because otherwise stacktrace() != stacktrace(false).
    # not sure why.  possibly b/c of re-ordering of base/sysimg.jl
    !isempty(stack) && startswith(string(stack[1].func),"jlcall_stacktrace") && popfirst!(stack)
    stack
end

Base.@hide_in_stacktrace stacktrace(c_funcs::Bool=false) = stacktrace(backtrace(), c_funcs)

"""
    remove_frames!(stack::StackTrace, name::Symbol)

Takes a `StackTrace` (a vector of `StackFrames`) and a function name (a `Symbol`) and
removes the `StackFrame` specified by the function name from the `StackTrace` (also removing
all frames above the specified function). Primarily used to remove `StackTraces` functions
from the `StackTrace` prior to returning it.
"""
function remove_frames!(stack::StackTrace, name::Symbol)
    splice!(stack, 1:something(findlast(frame -> frame.func == name, stack), 0))
    return stack
end

function remove_frames!(stack::StackTrace, names::Vector{Symbol})
    splice!(stack, 1:something(findlast(frame -> frame.func in names, stack), 0))
    return stack
end

"""
    remove_frames!(stack::StackTrace, m::Module)

Returns the `StackTrace` with all `StackFrame`s from the provided `Module` removed.
"""
function remove_frames!(stack::StackTrace, m::Module)
    filter!(f -> !from(f, m), stack)
    return stack
end

is_top_level_frame(f::StackFrame) = f.linfo isa CodeInfo || (f.linfo === nothing && f.func === top_level_scope_sym)

function show_spec_linfo(io::IO, frame::StackFrame)
    if frame.linfo === nothing
        if frame.func === empty_sym
            @printf(io, "ip:%#x", frame.pointer)
        elseif frame.func === top_level_scope_sym
            print(io, "top-level scope")
        else
            color = get(io, :color, false) && get(io, :backtrace, false) ?
                        Base.stackframe_function_color() :
                        :nothing
            printstyled(io, string(frame.func), color=color)
        end
    elseif frame.linfo isa MethodInstance
        if isa(frame.linfo.def, Method)
            Base.show_tuple_as_call(io, frame.linfo.def.name, frame.linfo.specTypes)
        else
            Base.show(io, frame.linfo)
        end
    elseif frame.linfo isa CodeInfo
        print(io, "top-level scope")
    end
end

function show(io::IO, frame::StackFrame; full_path::Bool=false)
    show_spec_linfo(io, frame)
    if frame.file !== empty_sym
        file_info = full_path ? string(frame.file) : basename(string(frame.file))
        print(io, " at ")
        Base.with_output_color(get(io, :color, false) && get(io, :backtrace, false) ? Base.stackframe_lineinfo_color() : :nothing, io) do io
            print(io, file_info, ":")
            if frame.line >= 0
                print(io, frame.line)
            else
                print(io, "?")
            end
        end
    end
    if frame.inlined
        print(io, " [inlined]")
    end
end

"""
    from(frame::StackFrame, filter_mod::Module) -> Bool

Returns whether the `frame` is from the provided `Module`
"""
function from(frame::StackFrame, m::Module)
    finfo = frame.linfo
    result = false

    if finfo isa MethodInstance
        frame_m = finfo.def
        isa(frame_m, Method) && (frame_m = frame_m.module)
        result = nameof(frame_m) === nameof(m)
    end

    return result
end

function Base.show(io::IO, ip::Base.InterpreterIP)
    print(io, typeof(ip))
    if ip.code isa CodeInfo
        print(io, " in top-level CodeInfo for $(ip.mod) at statement $(Int(ip.stmt))")
    else
        print(io, " in $(ip.code) at statement $(Int(ip.stmt))")
    end
end

end
