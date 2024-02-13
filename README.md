# methttp

Lean HTTP parser and utilities using only statically-allocated memory for Nim.

Its name is derived from Methamphetamine + HTTP.

Give your Nim app a boost of energy and focus with a library that is *leak free under ARC* and entirely predictable.
Applications using `methttp` report impressive weight loss owing to grealy reduced appetite for dynamic memory.


# About

`methttp` is a library designed to implement HTTP/1.1 without any dynamic memory allocation, avoiding copying data whenever possible as well.

Instead, it relies heavily on statically-allocated memory encoded into types, and the experimental `views` feature.
This lends itself to predictable performance and resource usage. All you need is the `sizeof` proc to find out how much memory you'll be using.

It does not include any I/O capabilities, and instead provides interfaces for wiring up parts of the library with your own I/O library,
such as the stdlib's [asyncnet](https://nim-lang.org/docs/asyncnet.html) or alaviss' [sys](https://github.com/alaviss/nim-sys).

Because it is not restricted to any particular I/O library, concurrency model, or operating system, `methttp` can be used anywhere Nim goes,
including on resource-constrained microcontrollers. It is also designed to work with Nim's ARC memory managemer.


# Regarding Exceptions

This library does not use exceptions at all. Instead, it relies on return values to indicate failure.
This decision was made because Nim exceptions are dynamically-allocated and can lead to unpredictable behavior.

While the API may be a little too C-like for comfort, keep in mind that this library is intentionally low-level and is intended to be
used by other library authors as the basis for their HTTP support.
Library authors may choose to use exceptions to represent `methttp` errors if they wish.


# Status

Currently, the library includes a pure-Nim HTTP/1.1 request parser.
It is missing a standardized API or stable release.

My current goal is to get it to a point where I can use it to build a full web framework with [sys](https://github.com/alaviss/nim-sys).
