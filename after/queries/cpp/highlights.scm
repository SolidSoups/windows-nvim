; extends

; #pragma region Name / #pragma endregion Name reads as section headings. Priority above the default 100,
; because nvim-treesitter re-parses the text after #pragma as C++ and its @variable/@type captures draw on top
((preproc_call
   directive: (preproc_directive) @_directive
   argument: (preproc_arg) @markup.heading)
 (#eq? @_directive "#pragma")
 (#match? @markup.heading "^\s*\(end\)\?region")
 (#set! priority 120))
