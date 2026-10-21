" Syntax for nvimterminals policy buffers: one Lua PATTERN per line.
" Policy lines are not Lua code -- "^ls" or "deny rm.*" must never light up
" as Lua syntax errors (that is why the filetype is nvimterminals_policy and
" not "lua"). Anything not matched below renders as Normal: a plain allow
" pattern.

" Re-claimable: only skip when OUR syntax is already active (filetype
" machinery elsewhere may have guessed a wrong syntax from the buffer name).
if exists("b:current_syntax") && b:current_syntax == "nvimterminals_policy"
  finish
endif

syntax case match

" comments and the seeded header
syntax match nvimterminalsPolicyComment /\s*#.*/
highlight default link nvimterminalsPolicyComment Comment

" deny lines (evaluated before allows)
syntax match nvimterminalsPolicyDeny /^\s*deny\s\+.\+/
highlight default link nvimterminalsPolicyDeny WarningMsg

" the lone wildcard allow
syntax match nvimterminalsPolicyWildcard /^\s*\*\s*$/
highlight default link nvimterminalsPolicyWildcard Special

let b:current_syntax = "nvimterminals_policy"
