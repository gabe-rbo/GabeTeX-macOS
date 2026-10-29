// Environments. Format: see CompletionCatalog.swift.
// Each row: name¦argumentsSnippet¦bodySnippet¦detail¦package. Inserted after `\begin{` as: name} + args + indented body + \end{name}.

extension CompletionCatalog {
    static let environmentsTable = #"""
# ── Document structure ───────────────────────────────────────────────────────
document¦¦$0¦Document body¦
abstract¦¦$0¦Abstract¦
titlepage¦¦$0¦Title page¦
appendices¦¦$0¦Appendices (appendix package)¦appendix
thebibliography¦{${1:99}}¦\bibitem{${2:key}} $0¦Bibliography with hand-written entries¦
theindex¦¦$0¦Index¦
filecontents¦{${1:references.bib}}¦$0¦Embed a file inside the document¦
comment¦¦$0¦Comment out a block of text¦verbatim
# ── Lists ────────────────────────────────────────────────────────────────────
itemize¦¦\item $0¦Bulleted list¦
enumerate¦¦\item $0¦Numbered list¦
description¦¦\item[${1:term}] $0¦Description list¦
# ── Displayed mathematics (amsmath) ──────────────────────────────────────────
equation¦¦$0¦Numbered single-line equation¦
equation*¦¦$0¦Unnumbered single-line equation¦
align¦¦${1:lhs} &= ${2:rhs} \\⏎$0¦Aligned equations, numbered (amsmath)¦amsmath
align*¦¦${1:lhs} &= ${2:rhs} \\⏎$0¦Aligned equations, unnumbered (amsmath)¦amsmath
alignat¦{${1:2}}¦${2:lhs} &= ${3:rhs} \\⏎$0¦Aligned equations with a column count (amsmath)¦amsmath
alignat*¦{${1:2}}¦${2:lhs} &= ${3:rhs} \\⏎$0¦Unnumbered aligned equations with a column count (amsmath)¦amsmath
flalign¦¦${1:lhs} &= ${2:rhs} \\⏎$0¦Full-width aligned equations (amsmath)¦amsmath
flalign*¦¦${1:lhs} &= ${2:rhs} \\⏎$0¦Unnumbered full-width aligned equations (amsmath)¦amsmath
gather¦¦${1:expr} \\⏎$0¦Centred equations, numbered (amsmath)¦amsmath
gather*¦¦${1:expr} \\⏎$0¦Centred equations, unnumbered (amsmath)¦amsmath
multline¦¦${1:first line}⏎$0¦Multi-line equation, numbered (amsmath)¦amsmath
multline*¦¦${1:first line}⏎$0¦Multi-line equation, unnumbered (amsmath)¦amsmath
split¦¦${1:lhs} &= ${2:rhs}$0¦Split one equation over several lines (amsmath)¦amsmath
aligned¦¦${1:lhs} &= ${2:rhs}$0¦Aligned block inside a math environment (amsmath)¦amsmath
alignedat¦{${1:2}}¦${2:lhs} &= ${3:rhs}$0¦Aligned block with a column count (amsmath)¦amsmath
gathered¦¦${1:expr}$0¦Gathered block inside a math environment (amsmath)¦amsmath
cases¦¦${1:value} & ${2:if condition} \\⏎$0¦Piecewise definition (amsmath)¦amsmath
dcases¦¦${1:value} & ${2:if condition} \\⏎$0¦Piecewise definition in display style (mathtools)¦mathtools
dcases*¦¦${1:value} & ${2:if condition} \\⏎$0¦Piecewise definition, display style, starred (mathtools)¦mathtools
rcases¦¦${1:value} & ${2:if condition} \\⏎$0¦Right-hand brace piecewise definition (amsmath)¦amsmath
subequations¦¦$0¦Number equations with letters inside a number (amsmath)¦amsmath
eqnarray¦¦${1:lhs} &= ${2:rhs}⏎$0¦Old aligned equations (kernel; prefer align)¦
eqnarray*¦¦${1:lhs} &= ${2:rhs}⏎$0¦Old unnumbered aligned equations (kernel; prefer align*)¦
math¦¦$0¦Inline mathematics as an environment¦
displaymath¦¦$0¦Unnumbered display mathematics¦
# ── Matrices (amsmath) ───────────────────────────────────────────────────────
matrix¦¦${1:a} & ${2:b} \\⏎$0¦Matrix without delimiters (amsmath)¦amsmath
pmatrix¦¦${1:a} & ${2:b} \\⏎$0¦Matrix in parentheses (amsmath)¦amsmath
bmatrix¦¦${1:a} & ${2:b} \\⏎$0¦Matrix in square brackets (amsmath)¦amsmath
Bmatrix¦¦${1:a} & ${2:b} \\⏎$0¦Matrix in braces (amsmath)¦amsmath
vmatrix¦¦${1:a} & ${2:b} \\⏎$0¦Matrix with single bars, for determinants (amsmath)¦amsmath
Vmatrix¦¦${1:a} & ${2:b} \\⏎$0¦Matrix with double bars (amsmath)¦amsmath
smallmatrix¦¦${1:a} & ${2:b} \\⏎$0¦Compact matrix for inline use (amsmath)¦amsmath
# ── Theorem-like environments (amsthm; all but proof need \newtheorem) ──────
theorem¦¦$0¦Numbered theorem (needs \newtheorem)¦amsthm
lemma¦¦$0¦Numbered lemma (needs \newtheorem)¦amsthm
proposition¦¦$0¦Numbered proposition (needs \newtheorem)¦amsthm
corollary¦¦$0¦Numbered corollary (needs \newtheorem)¦amsthm
definition¦¦$0¦Numbered definition (needs \newtheorem)¦amsthm
remark¦¦$0¦Numbered remark (needs \newtheorem)¦amsthm
example¦¦$0¦Numbered example (needs \newtheorem)¦amsthm
proof¦¦$0¦Proof, ending with a box (provided by amsthm)¦amsthm
# ── Floats ───────────────────────────────────────────────────────────────────
figure¦[${1:htbp}]¦\centering⏎\includegraphics[width=${2:0.8}\linewidth]{${3:file}}⏎\caption{${4:caption}}⏎\label{fig:${5:label}}$0¦Floating figure¦
figure*¦[${1:htbp}]¦\centering⏎\includegraphics[width=${2:0.8}\linewidth]{${3:file}}⏎\caption{${4:caption}}⏎\label{fig:${5:label}}$0¦Figure spanning two columns¦
table¦[${1:htbp}]¦\centering⏎\caption{${2:caption}}⏎\label{tab:${3:label}}⏎$0¦Floating table¦
table*¦[${1:htbp}]¦\centering⏎\caption{${2:caption}}⏎\label{tab:${3:label}}⏎$0¦Table spanning two columns¦
wrapfigure¦{${1:r}}{${2:0.4\textwidth}}¦\centering⏎\includegraphics[width=\linewidth]{${3:file}}⏎\caption{${4:caption}}$0¦Figure wrapped in text¦wrapfig
subfigure¦[${1:b}]{${2:0.45\textwidth}}¦\centering⏎\includegraphics[width=\linewidth]{${3:file}}⏎\caption{${4:caption}}⏎\label{fig:${5:label}}$0¦Subfigure¦subcaption
algorithm¦[${1:htbp}]¦\caption{${2:caption}}⏎\label{alg:${3:label}}⏎$0¦Floating algorithm¦algorithm
algorithmic¦¦$0¦Algorithmic pseudocode¦algorithmic
# ── Tables ───────────────────────────────────────────────────────────────────
tabular¦{${1:cc}}¦$0¦Table with aligned columns¦
tabularx¦{${1:\textwidth}}{${2:lX}}¦$0¦Table whose columns stretch to a width¦tabularx
longtable¦{${1:lll}}¦$0¦Table that spans several pages¦longtable
array¦{${1:cc}}¦$0¦Array, usable inside math¦
# ── Alignment and blocks ─────────────────────────────────────────────────────
center¦¦$0¦Centred block¦
flushleft¦¦$0¦Left-aligned block¦
flushright¦¦$0¦Right-aligned block¦
minipage¦[${1:t}]{${2:0.5\textwidth}}¦$0¦Box of paragraph width¦
quote¦¦$0¦Indented quotation¦
quotation¦¦$0¦Indented quotation with paragraph indents¦
verse¦¦$0¦Poetry with line breaks¦
singlespace¦¦$0¦Single line spacing¦setspace
onehalfspace¦¦$0¦One-and-a-half line spacing¦setspace
doublespace¦¦$0¦Double line spacing¦setspace
multicols¦{${1:2}}¦$0¦Several columns of text¦multicol
tcolorbox¦[${1:title=Title}]¦$0¦Coloured box¦tcolorbox
# ── Code and verbatim ────────────────────────────────────────────────────────
verbatim¦¦$0¦Verbatim text¦
Verbatim¦¦$0¦Verbatim text with options¦fancyvrb
lstlisting¦[language=${1:Python}]¦$0¦Listing of source code¦listings
minted¦{${1:python}}¦$0¦Highlighted source code¦minted
# ── Pictures and diagrams ────────────────────────────────────────────────────
tikzpicture¦[${1:options}]¦$0¦TikZ picture¦tikz
tikzcd¦¦${1:A} \arrow[r, "${2:f}"] \arrow[d] & ${3:B} \arrow[d] \\⏎${4:C} \arrow[r] & ${5:D}$0¦Commutative diagram: 2x2 square (tikz-cd)¦tikz-cd
CD¦¦A @>${1:f}>> B⏎@VV{${2:g}}V⏎C @>>> D$0¦Commutative diagram (amscd)¦amscd
axis¦[${1:xlabel=x}]¦$0¦Plot axes (pgfplots)¦pgfplots
# ── Beamer ───────────────────────────────────────────────────────────────────
frame¦{${1:Title}}¦$0¦Beamer slide¦beamer
block¦{${1:Title}}¦$0¦Beamer block¦beamer
alertblock¦{${1:Title}}¦$0¦Beamer alert block¦beamer
exampleblock¦{${1:Title}}¦$0¦Beamer example block¦beamer
columns¦[${1:T}]¦\begin{column}{${2:0.5\textwidth}}⏎⇥$0⏎\end{column}¦Beamer columns¦beamer
column¦{${1:0.5\textwidth}}¦$0¦Beamer column¦beamer
# ── Layout, boxes and misc ───────────────────────────────────────────────────
spacing¦{${1:1.5}}¦$0¦Custom line spacing¦setspace
multicols*¦{${1:2}}¦$0¦Several columns of text, unbalanced¦multicol
adjustwidth¦{${1:1cm}}{${2:1cm}}¦$0¦Block indented on both sides¦changepage
adjustbox¦[${1:width=\linewidth}]¦$0¦Box that adjusts its contents¦adjustbox
mdframed¦¦$0¦Framed paragraph that can break across pages¦mdframed
framed¦¦$0¦Framed box¦framed
shaded¦¦$0¦Shaded box¦framed
landscape¦¦$0¦Landscape page¦pdflscape
sidewaystable¦[${1:htbp}]¦\centering⏎\caption{${2:caption}}⏎\label{tab:${3:label}}⏎$0¦Table rotated to landscape¦rotating
sidewaysfigure¦[${1:htbp}]¦\centering⏎\includegraphics[width=${2:0.8}\linewidth]{${3:file}}⏎\caption{${4:caption}}⏎\label{fig:${5:label}}$0¦Figure rotated to landscape¦rotating
tabbing¦¦$0¦Tab-aligned text¦
picture¦(${1:200,200})¦$0¦Picture environment with coordinates¦
sloppypar¦¦$0¦Paragraph with relaxed line breaking¦
verbatim*¦¦$0¦Verbatim text with visible spaces¦
scope¦[${1:options}]¦$0¦Group of TikZ commands with shared options¦tikz
"""#
}
