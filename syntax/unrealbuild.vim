if exists("b:current_syntax")
  finish
endif

syntax match unrealbuildCommand   /^> .*/
syntax match unrealbuildProgress  /^\[\d\+\/\d\+\]/

syntax match unrealbuildPath      /\v^\s*\zs\a:[\\/][^(]*\(\d+(,\d+)?\)/
syntax match unrealbuildError     /\v<(fatal )?[Ee]rror( [A-Z]+\d+)?:.*/
syntax match unrealbuildWarning   /\v<[Ww]arning( [A-Z]+\d+)?:.*/
syntax match unrealbuildNote      /\v<note:.*/

syntax match unrealbuildSucceeded /\v^\S+ build succeeded .*/
syntax match unrealbuildFailed    /\v^\S+ build failed .*/
syntax match unrealbuildCancelled /\v^\S+ build cancelled .*/

highlight default link unrealbuildCommand   Comment
highlight default link unrealbuildProgress  Number
highlight default link unrealbuildPath      Directory
highlight default link unrealbuildError     DiagnosticError
highlight default link unrealbuildWarning   DiagnosticWarn
highlight default link unrealbuildNote      DiagnosticInfo
highlight default link unrealbuildSucceeded DiagnosticOk
highlight default link unrealbuildFailed    DiagnosticError
highlight default link unrealbuildCancelled DiagnosticWarn

let b:current_syntax = "unrealbuild"
