# ycmd identifier completion for Neovim.

**THIS IS BARELY FUNCTIONING, LOOK AROUND, TRY IT IF YOU WANT BUT DON'T COMPLAINT IF IT DOESN'T DO WHAT YOU EXPECT!**

- YouCompleteMe wrapped in a C++ msgpack-rpc binary.
- Neovim's tree-sitter API's based identifier extraction.
- As much as Lua as possible (but some VimL is still needed :/)
- Profit (at least for me).

# Rationale

Why do I need this instead of using just YouCompleteMe?

Primarly because I wanted to experiment with Neovim specific technologies.

Right now YouCompleteMe does buffer completion like:
- send the buffer to the Python server
- extract the identifiers based on a regex for each language
- store the identifiers

I don't like that I need Python in order to use YouCompleteMe (plus I'm not
that good at writing Python code even if I've done it for YouCompleteMe). This
version uses the "binary" approach where I have a binary that I can pre-build
for each platform where I work on, download it and be done with it.
I wanted to try to use the tree-sitter APIs to extract the identifiers from a buffer.

This way each component will do what it does best where YouCompleteMe will simply returns the proper identifiers when it is asked for them.

# What about LSP

I rely heavily on the buffer completion of YouCompleteMe at the moment while I don't use any LSP. If that time comes I will probably use the Neovim native capability anyway.

# TODOs
- [ ] Actually use a saner CMake build for the C++. It will invole changing the CMake build of ycmd itself in order to expose a new target for the identifier only functionality.
- [ ] Put in place the whole CI/CD for the ycm binary (probably Azure Pipeline).
- [ ] Find a way to properly test this thing. I would love to have something like the screen test of Neovim itself... maybe use exactly that!
- [ ] Integrate with native LSP client in order to provide YCM fuzzy lookup (maybe look at https://github.com/haorenW1025/completion-nvim).
- [x] Try to move the VimL autocmd to the homemade lua API to experiment and prove the API (maybe if it does I could try to implement it directly in Neovim)
- [ ] Put in place statusline support for marking when we do not have ycm active due to missing parser or query
- [ ] Update to latest ycmd (they moved to C++17 completely and boost was removed entirely making part of my branch moot)
