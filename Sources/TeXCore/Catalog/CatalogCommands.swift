// Text-mode and general commands, and math-mode commands. Format: see CompletionCatalog.swift.
// Snippet notes: a backslash may not sit directly before a tab stop (\$ is the escape for a literal dollar),
// so placeholders such as ${1:\name} carry the backslash inside their default text.

extension CompletionCatalog {
    static let commandsTable = #"""
# ── Preamble and document setup ──────────────────────────────────────────────
\documentclass¦\documentclass[${1:12pt}]{${2:article}}$0¦Declare the document class¦
\usepackage¦\usepackage{${1:package}}$0¦Load a package (options go in [...] before the braces)¦
\RequirePackage¦\RequirePackage{${1:package}}$0¦Load a package from inside a .sty or .cls file¦
\newcommand¦\newcommand{${1:\name}}[${2:0}]{${3:definition}}$0¦Define a new command¦
\renewcommand¦\renewcommand{${1:\name}}[${2:0}]{${3:definition}}$0¦Redefine an existing command¦
\providecommand¦\providecommand{${1:\name}}[${2:0}]{${3:definition}}$0¦Define a command if it is undefined¦
\newenvironment¦\newenvironment{${1:name}}{${2:begin code}}{${3:end code}}$0¦Define a new environment¦
\renewenvironment¦\renewenvironment{${1:name}}{${2:begin code}}{${3:end code}}$0¦Redefine an environment¦
\newtheorem¦\newtheorem{${1:theorem}}{${2:Theorem}}[${3:section}]$0¦Define a numbered theorem-like environment¦
\theoremstyle¦\theoremstyle{${1:plain}}$0¦Theorem style: plain, definition or remark¦amsthm
\qedhere¦\qedhere$0¦Put the end-of-proof box on this line¦amsthm
\DeclareMathOperator¦\DeclareMathOperator{${1:\name}}{${2:text}}$0¦Declare an upright math operator¦amsmath
\NewDocumentCommand¦\NewDocumentCommand{${1:\name}}{${2:m}}{${3:definition}}$0¦Define a command with xparse argument specifiers¦
\RenewDocumentCommand¦\RenewDocumentCommand{${1:\name}}{${2:m}}{${3:definition}}$0¦Redefine a command with xparse argument specifiers¦
\NewDocumentEnvironment¦\NewDocumentEnvironment{${1:name}}{${2:m}}{${3:begin code}}{${4:end code}}$0¦Define an environment with xparse argument specifiers¦
\DeclarePairedDelimiter¦\DeclarePairedDelimiter{${1:\name}}{${2:\lvert}}{${3:\rvert}}$0¦Paired delimiter with starred auto-sizing¦mathtools
\let¦\let${1:\new}=${2:\old}$0¦Make one control sequence an alias of another¦
\def¦\def${1:\name}{${2:definition}}$0¦Define a macro with TeX primitives¦
\makeatletter¦\makeatletter$0\makeatother¦Treat @ as a letter inside command names¦
\makeatother¦\makeatother¦Restore @ as a non-letter¦
\DeclareOption¦\DeclareOption{${1:option}}{${2:code}}$0¦Declare a class or package option¦
\ProcessOptions¦\ProcessOptions\relax$0¦Process the declared options¦
\newif¦\newif\if${1:flag}$0¦Define a conditional¦
\newcounter¦\newcounter{${1:counter}}$0¦Define a new counter¦
\setcounter¦\setcounter{${1:counter}}{${2:0}}$0¦Set a counter value¦
\addtocounter¦\addtocounter{${1:counter}}{${2:1}}$0¦Add to a counter¦
\stepcounter¦\stepcounter{${1:counter}}$0¦Step a counter and reset the deeper ones¦
\refstepcounter¦\refstepcounter{${1:counter}}$0¦Step a counter so that \label refers to it¦
\value¦\value{${1:counter}}¦Value of a counter¦
\arabic¦\arabic{${1:counter}}¦Counter in arabic numerals¦
\roman¦\roman{${1:counter}}¦Counter in lowercase roman numerals¦
\Roman¦\Roman{${1:counter}}¦Counter in uppercase roman numerals¦
\alph¦\alph{${1:counter}}¦Counter in lowercase letters¦
\Alph¦\Alph{${1:counter}}¦Counter in uppercase letters¦
\numberwithin¦\numberwithin{${1:equation}}{${2:section}}$0¦Number equations within sections¦amsmath
\allowdisplaybreaks¦\allowdisplaybreaks$0¦Allow page breaks inside display equations¦amsmath
\newlength¦\newlength{${1:\len}}$0¦Define a length¦
\setlength¦\setlength{${1:\parindent}}{${2:1em}}$0¦Set a length¦
\addtolength¦\addtolength{${1:\parskip}}{${2:1em}}$0¦Add to a length¦
\hyphenation¦\hyphenation{${1:word-list}}$0¦Hyphenation exceptions¦
\geometry¦\geometry{${1:margin=2.5cm}}$0¦Page layout options¦geometry
\onehalfspacing¦\onehalfspacing$0¦One-and-a-half line spacing¦setspace
\doublespacing¦\doublespacing$0¦Double line spacing¦setspace
\singlespacing¦\singlespacing$0¦Single line spacing¦setspace
\setstretch¦\setstretch{${1:1.2}}$0¦Line spacing factor¦setspace
\linespread¦\linespread{${1:1.2}}$0¦Line spacing factor (kernel)¦
\baselinestretch¦\renewcommand{\baselinestretch}{${1:1.2}}$0¦Line spacing factor (kernel)¦
\titleformat¦\titleformat{${1:\section}}{${2:\bfseries}}{${3:\thesection}}{${4:1em}}{${5:#1}}$0¦Format a sectioning command¦titlesec
\titlespacing¦\titlespacing{${1:\section}}{${2:0pt}}{${3:1ex}}{${4:1ex}}$0¦Spacing around a sectioning command¦titlesec
\fancyhf¦\fancyhf{}$0¦Clear all header and footer fields¦fancyhdr
\fancyhead¦\fancyhead[${1:C}]{${2:text}}$0¦Set a header field¦fancyhdr
\fancyfoot¦\fancyfoot[${1:C}]{${2:text}}$0¦Set a footer field¦fancyhdr
\lhead¦\lhead{${1:text}}$0¦Left header field¦fancyhdr
\rhead¦\rhead{${1:text}}$0¦Right header field¦fancyhdr
\pagestyle¦\pagestyle{${1:headings}}$0¦Page style for the rest of the document¦
\thispagestyle¦\thispagestyle{${1:empty}}$0¦Page style for this page¦
\pagenumbering¦\pagenumbering{${1:arabic}}$0¦Page number style¦
\selectlanguage¦\selectlanguage{${1:brazilian}}$0¦Switch the document language¦babel
\foreignlanguage¦\foreignlanguage{${1:brazilian}}{${2:text}}$0¦Typeset a phrase in another language¦babel
\enquote¦\enquote{${1:text}}$0¦Localised quotation marks¦csquotes
\makeindex¦\makeindex$0¦Enable the index¦makeidx
\index¦\index{${1:term}}$0¦Index entry¦makeidx
\printindex¦\printindex$0¦Print the index¦makeidx
\title¦\title{${1:title}}$0¦Set the title¦
\author¦\author{${1:name}}$0¦Set the author¦
\date¦\date{${1:\today}}$0¦Set the date¦
\today¦¦Today's date¦
\thanks¦\thanks{${1:note}}$0¦Footnote in the title block¦
\maketitle¦\maketitle$0¦Print the title block¦
\tableofcontents¦\tableofcontents$0¦Table of contents¦
\listoffigures¦\listoffigures$0¦List of figures¦
\listoftables¦\listoftables$0¦List of tables¦
\appendix¦\appendix$0¦Start the appendices¦
\frontmatter¦\frontmatter$0¦Start front matter (book, report, memoir)¦
\mainmatter¦\mainmatter$0¦Start main matter (book, report, memoir)¦
\backmatter¦\backmatter$0¦Start back matter (book, report, memoir)¦
\include¦\include{${1:chapter}}$0¦Include a file on a new page¦
\includeonly¦\includeonly{${1:chapter}}$0¦Compile only the listed included files¦
\input¦\input{${1:file}}$0¦Input a file inline¦
\InputIfFileExists¦\InputIfFileExists{${1:file}}{${2:found}}{${3:missing}}$0¦Input a file only if it exists¦
\subfile¦\subfile{${1:file}}$0¦Include a subfile with its own preamble¦subfiles
\import¦\import{${1:dir/}}{${2:file}}$0¦Input a file from a directory¦import
\graphicspath¦\graphicspath{{${1:figures/}}}$0¦Directories searched for graphics¦graphicx
# ── Sectioning ───────────────────────────────────────────────────────────────
\part¦\part{${1:title}}$0¦Part heading¦
\chapter¦\chapter{${1:title}}$0¦Chapter heading (book, report)¦
\section¦\section{${1:title}}$0¦Section heading¦
\subsection¦\subsection{${1:title}}$0¦Subsection heading¦
\subsubsection¦\subsubsection{${1:title}}$0¦Subsubsection heading¦
\paragraph¦\paragraph{${1:title}}$0¦Paragraph heading¦
\subparagraph¦\subparagraph{${1:title}}$0¦Subparagraph heading¦
\chapter*¦\chapter*{${1:title}}$0¦Unnumbered chapter heading¦
\section*¦\section*{${1:title}}$0¦Unnumbered section heading¦
\subsection*¦\subsection*{${1:title}}$0¦Unnumbered subsection heading¦
\subsubsection*¦\subsubsection*{${1:title}}$0¦Unnumbered subsubsection heading¦
# ── Bibliography ─────────────────────────────────────────────────────────────
\bibliographystyle¦\bibliographystyle{${1:plain}}$0¦Choose the BibTeX style¦
\bibliography¦\bibliography{${1:references}}$0¦Load BibTeX database files¦
\bibitem¦\bibitem{${1:key}} $0¦Entry of a thebibliography environment¦
\nocite¦\nocite{${1:key}}$0¦Add to the bibliography without citing¦
\addbibresource¦\addbibresource{${1:references.bib}}$0¦Load a .bib file¦biblatex
\printbibliography¦\printbibliography$0¦Print the bibliography¦biblatex
\cite¦\cite{${1:key}}$0¦Citation¦
\citep¦\citep{${1:key}}$0¦Parenthetical citation¦natbib
\citet¦\citet{${1:key}}$0¦Textual citation¦natbib
\citealt¦\citealt{${1:key}}$0¦Citation without parentheses¦natbib
\citealp¦\citealp{${1:key}}$0¦Parenthetical citation without the author¦natbib
\citeauthor¦\citeauthor{${1:key}}$0¦Author names only¦natbib
\citeyear¦\citeyear{${1:key}}$0¦Year only¦natbib
\parencite¦\parencite{${1:key}}$0¦Parenthetical citation¦biblatex
\textcite¦\textcite{${1:key}}$0¦Textual citation¦biblatex
\autocite¦\autocite{${1:key}}$0¦Context-dependent citation¦biblatex
\footcite¦\footcite{${1:key}}$0¦Citation in a footnote¦biblatex
\supercite¦\supercite{${1:key}}$0¦Superscript citation¦biblatex
\cites¦\cites{${1:key1}}{${2:key2}}$0¦Several citations¦biblatex
\textcites¦\textcites{${1:key1}}{${2:key2}}$0¦Several textual citations¦biblatex
\parencites¦\parencites{${1:key1}}{${2:key2}}$0¦Several parenthetical citations¦biblatex
\autocites¦\autocites{${1:key1}}{${2:key2}}$0¦Several context-dependent citations¦biblatex
# ── Cross-references and links ───────────────────────────────────────────────
\label¦\label{${1:key}}$0¦Label for cross-references¦
\ref¦\ref{${1:key}}$0¦Reference the number of a label¦
\pageref¦\pageref{${1:key}}$0¦Reference the page of a label¦
\eqref¦\eqref{${1:key}}$0¦Equation number in parentheses¦amsmath
\autoref¦\autoref{${1:key}}$0¦Reference with the object name¦hyperref
\nameref¦\nameref{${1:key}}$0¦Reference the title of a labelled item¦hyperref
\cref¦\cref{${1:key}}$0¦Smart reference with the type name¦cleveref
\Cref¦\Cref{${1:key}}$0¦Smart reference, capitalised¦cleveref
\crefrange¦\crefrange{${1:key1}}{${2:key2}}$0¦Smart reference to a range¦cleveref
\vref¦\vref{${1:key}}$0¦Reference with page information¦varioref
\hyperref¦\hyperref[${1:key}]{${2:text}}$0¦Link to a label¦hyperref
\hypertarget¦\hypertarget{${1:name}}{${2:text}}$0¦Named anchor¦hyperref
\hyperlink¦\hyperlink{${1:name}}{${2:text}}$0¦Link to a named anchor¦hyperref
\href¦\href{${1:https://example.com}}{${2:text}}$0¦Hyperlink¦hyperref
\url¦\url{${1:https://example.com}}$0¦Typeset a URL¦hyperref
\nolinkurl¦\nolinkurl{${1:url}}$0¦URL without a link¦hyperref
\texorpdfstring¦\texorpdfstring{${1:TeX text}}{${2:PDF text}}$0¦Different text for the PDF bookmarks¦hyperref
\hypersetup¦\hypersetup{${1:colorlinks=true}}$0¦Set hyperref options¦hyperref
# ── Footnotes and notes ──────────────────────────────────────────────────────
\footnote¦\footnote{${1:text}}$0¦Footnote¦
\footnotemark¦\footnotemark$0¦Footnote mark only¦
\footnotetext¦\footnotetext{${1:text}}$0¦Footnote text only¦
\marginpar¦\marginpar{${1:note}}$0¦Note in the margin¦
\ensuremath¦\ensuremath{${1:\alpha}}$0¦Force math mode inside text¦
\phantom¦\phantom{${1:text}}$0¦Invisible text of the same size¦
\textsuperscript¦\textsuperscript{${1:text}}$0¦Superscript text¦
\textsubscript¦\textsubscript{${1:text}}$0¦Subscript text¦
# ── Page and line breaks, spacing ────────────────────────────────────────────
\newpage¦¦Start a new page¦
\clearpage¦¦Flush floats and start a new page¦
\cleardoublepage¦¦Start a new odd-numbered page¦
\pagebreak¦\pagebreak[${1:4}]$0¦Break the page here¦
\linebreak¦\linebreak[${1:4}]$0¦Break the line here¦
\nolinebreak¦\nolinebreak[${1:4}]$0¦Discourage a line break here¦
\nopagebreak¦\nopagebreak[${1:4}]$0¦Discourage a page break here¦
\newline¦¦Line break¦
\\¦¦Line break (end of a table row or a display line)¦
\par¦¦Paragraph break¦
\noindent¦¦Do not indent this paragraph¦
\indent¦¦Indent this paragraph¦
\centering¦¦Centre the following content¦
\raggedright¦¦Left-aligned, ragged right¦
\raggedleft¦¦Right-aligned, ragged left¦
\hfill¦¦Horizontal stretch¦
\vfill¦¦Vertical stretch¦
\hspace¦\hspace{${1:1em}}$0¦Horizontal space¦
\vspace¦\vspace{${1:1em}}$0¦Vertical space¦
\hspace*¦\hspace*{${1:1em}}$0¦Horizontal space that survives line breaks¦
\vspace*¦\vspace*{${1:1em}}$0¦Vertical space that survives page breaks¦
\smallskip¦¦Small vertical skip¦
\medskip¦¦Medium vertical skip¦
\bigskip¦¦Large vertical skip¦
\quad¦¦Space of one em¦
\qquad¦¦Space of two em¦
\,¦¦Thin space¦
\:¦¦Medium space¦
\;¦¦Thick space¦
\!¦¦Negative thin space¦
\enspace¦¦Space of half an em¦
\ldots¦¦Ellipsis¦
\dots¦¦Ellipsis¦
\FloatBarrier¦\FloatBarrier$0¦Place all pending floats here (placeins)¦placeins
# ── Text formatting and fonts ────────────────────────────────────────────────
\textbf¦\textbf{${1:text}}$0¦Bold text¦
\textit¦\textit{${1:text}}$0¦Italic text¦
\textsl¦\textsl{${1:text}}$0¦Slanted text¦
\textsc¦\textsc{${1:text}}$0¦Small caps¦
\texttt¦\texttt{${1:text}}$0¦Monospaced text¦
\textrm¦\textrm{${1:text}}$0¦Roman text¦
\textsf¦\textsf{${1:text}}$0¦Sans-serif text¦
\textmd¦\textmd{${1:text}}$0¦Medium weight¦
\textup¦\textup{${1:text}}$0¦Upright text¦
\textnormal¦\textnormal{${1:text}}$0¦Normal document font¦
\emph¦\emph{${1:text}}$0¦Emphasised text¦
\underline¦\underline{${1:text}}$0¦Underlined text¦
\uline¦\uline{${1:text}}$0¦Underline that can break across lines¦ulem
\sout¦\sout{${1:text}}$0¦Strikethrough¦ulem
\bfseries¦¦Bold series (declaration)¦
\itshape¦¦Italic shape (declaration)¦
\scshape¦¦Small caps shape (declaration)¦
\ttfamily¦¦Monospaced family (declaration)¦
\sffamily¦¦Sans-serif family (declaration)¦
\rmfamily¦¦Roman family (declaration)¦
\tiny¦¦Tiny size (declaration)¦
\scriptsize¦¦Script size (declaration)¦
\footnotesize¦¦Footnote size (declaration)¦
\small¦¦Small size (declaration)¦
\normalsize¦¦Normal size (declaration)¦
\large¦¦Large size (declaration)¦
\Large¦¦Larger size (declaration)¦
\LARGE¦¦Even larger size (declaration)¦
\huge¦¦Huge size (declaration)¦
\Huge¦¦Largest size (declaration)¦
\LaTeX¦¦The LaTeX logo¦
\LaTeXe¦¦The LaTeX2e logo¦
\TeX¦¦The TeX logo¦
\S¦¦Section sign¦
\P¦¦Pilcrow sign¦
\dag¦¦Dagger¦
\ddag¦¦Double dagger¦
\copyright¦¦Copyright sign¦
\%¦¦Percent sign¦
\&¦¦Ampersand¦
\_¦¦Underscore¦
# ── Boxes and rules ──────────────────────────────────────────────────────────
\mbox¦\mbox{${1:text}}$0¦Unbreakable box¦
\makebox¦\makebox[${1:width}][${2:c}]{${3:text}}$0¦Box of a given width¦
\parbox¦\parbox[${1:t}]{${2:5cm}}{${3:text}}$0¦Paragraph-sized box¦
\framebox¦\framebox[${1:width}][${2:c}]{${3:text}}$0¦Framed box¦
\fbox¦\fbox{${1:text}}$0¦Framed box¦
\rule¦\rule{${1:1em}}{${2:1pt}}$0¦Rule (solid black box)¦
\raisebox¦\raisebox{${1:0.5ex}}{${2:text}}$0¦Raise or lower a box¦
\scalebox¦\scalebox{${1:0.5}}{${2:text}}$0¦Scale a box¦graphicx
\resizebox¦\resizebox{${1:\textwidth}}{!}{${2:content}}$0¦Resize a box to a given size¦graphicx
\rotatebox¦\rotatebox{${1:90}}{${2:text}}$0¦Rotate a box¦graphicx
\boxed¦\boxed{${1:formula}}$0¦Box around a formula¦amsmath
# ── Lists ────────────────────────────────────────────────────────────────────
\item¦\item $0¦List item¦
\setlist¦\setlist[${1:itemize}]{${2:itemsep=0.5em}}$0¦Customise list spacing and labels¦enumitem
# ── Colours ──────────────────────────────────────────────────────────────────
\textcolor¦\textcolor{${1:red}}{${2:text}}$0¦Coloured text¦xcolor
\color¦\color{${1:red}}$0¦Switch the current colour¦xcolor
\colorbox¦\colorbox{${1:yellow}}{${2:text}}$0¦Text on a coloured background¦xcolor
\fcolorbox¦\fcolorbox{${1:black}}{${2:yellow}}{${3:text}}$0¦Framed coloured box¦xcolor
\definecolor¦\definecolor{${1:name}}{${2:rgb}}{${3:0,0.5,1}}$0¦Define a named colour¦xcolor
\colorlet¦\colorlet{${1:name}}{${2:red}}$0¦Define a colour from another colour¦xcolor
\pagecolor¦\pagecolor{${1:yellow}}$0¦Background colour of the page¦xcolor
\rowcolor¦\rowcolor{${1:gray!20}}$0¦Background colour of a table row¦colortbl
\cellcolor¦\cellcolor{${1:gray!20}}$0¦Background colour of a table cell¦colortbl
# ── Tables ───────────────────────────────────────────────────────────────────
\toprule¦\toprule$0¦Thick top rule¦booktabs
\midrule¦\midrule$0¦Middle rule¦booktabs
\bottomrule¦\bottomrule$0¦Thick bottom rule¦booktabs
\cmidrule¦\cmidrule(${1:lr}){${2:2-3}}$0¦Partial rule across columns¦booktabs
\addlinespace¦\addlinespace[${1:0.5em}]$0¦Extra space between rows¦booktabs
\multicolumn¦\multicolumn{${1:2}}{${2:c}}{${3:text}}$0¦Cell spanning several columns¦
\multirow¦\multirow{${1:2}}{*}{${2:text}}$0¦Cell spanning several rows¦multirow
\hline¦\hline$0¦Horizontal rule in a table¦
\cline¦\cline{${1:2-3}}$0¦Partial horizontal rule¦
\vline¦\vline$0¦Vertical rule in a table¦
\arraybackslash¦\arraybackslash$0¦Restore the row-break command inside a column specifier¦array
\tabularnewline¦\tabularnewline$0¦End of a table row¦
\tabcolsep¦\setlength{\tabcolsep}{${1:6pt}}$0¦Column separation length¦
\arraystretch¦\renewcommand{\arraystretch}{${1:1.2}}$0¦Row height factor¦
# ── Figures and graphics ─────────────────────────────────────────────────────
\includegraphics¦\includegraphics[width=${1:0.8}\linewidth]{${2:file}}$0¦Include an image¦graphicx
\includepdf¦\includepdf[pages=${1:-}]{${2:file.pdf}}$0¦Include pages of a PDF¦pdfpages
\caption¦\caption{${1:caption}}$0¦Caption for a float¦
\captionof¦\captionof{${1:table}}{${2:caption}}$0¦Caption outside a float¦caption
\captionsetup¦\captionsetup{${1:font=small}}$0¦Configure captions¦caption
\subcaption¦\subcaption{${1:caption}}$0¦Caption for a subfigure¦subcaption
\subfloat¦\subfloat[${1:subcaption}]{${2:content}}$0¦Subfigure¦subfig
\subref¦\subref{${1:key}}$0¦Reference a subfigure¦subcaption
\wrapfigure¦\wrapfigure{${1:r}}{${2:0.5\textwidth}}{${3:content}}$0¦Figure wrapped in text¦wrapfig
\figurename¦¦Word "Figure" (for localisation)¦
\tablename¦¦Word "Table" (for localisation)¦
# ── Verbatim and code ────────────────────────────────────────────────────────
\verb¦\verb|${1:code}|$0¦Inline verbatim text¦
\lstinline¦\lstinline|${1:code}|$0¦Inline listing¦listings
\lstset¦\lstset{${1:basicstyle=\ttfamily}}$0¦Set listings options¦listings
\lstinputlisting¦\lstinputlisting[language=${1:Python}]{${2:file}}$0¦Include a source file¦listings
\mintinline¦\mintinline{${1:python}}{${2:code}}$0¦Inline highlighted code¦minted
\inputminted¦\inputminted[${1:linenos}]{${2:python}}{${3:file}}$0¦Include a highlighted source file¦minted
# ── TikZ and tikz-cd ─────────────────────────────────────────────────────────
\tikz¦\tikz[${1:options}]{\draw ${2:(0,0) -- (1,1)};}$0¦Inline TikZ picture¦tikz
\tikzset¦\tikzset{${1:every node/.style={}}}$0¦Define TikZ styles¦tikz
\usetikzlibrary¦\usetikzlibrary{${1:arrows.meta}}$0¦Load TikZ libraries¦tikz
\draw¦\draw[${1:options}] ${2:(0,0)} -- ${3:(1,1)};$0¦Draw a path¦tikz
\path¦\path[${1:options}] ${2:(0,0)} -- ${3:(1,1)};$0¦Define a path without drawing it¦tikz
\node¦\node[${1:options}] at (${2:0,0}) {${3:text}};$0¦Place a node¦tikz
\fill¦\fill[${1:color}] ${2:(0,0)} circle (${3:0.1});$0¦Fill a path or shape¦tikz
\filldraw¦\filldraw[${1:options}] ${2:(0,0)} rectangle ${3:(1,1)};$0¦Fill and draw a path¦tikz
\coordinate¦\coordinate (${1:name}) at (${2:0,0});$0¦Named coordinate¦tikz
\clip¦\clip ${1:(0,0)} rectangle ${2:(1,1)};$0¦Clip the picture to a path¦tikz
\foreach¦\foreach ${1:\x} in {${2:1,...,5}} {$0}¦Loop over a list of values¦pgffor
\arrow¦\arrow[${1:r}, "${2:f}"]$0¦Arrow in a tikz-cd diagram¦tikz-cd
# ── Beamer ───────────────────────────────────────────────────────────────────
\frametitle¦\frametitle{${1:title}}$0¦Title of the current frame¦beamer
\framesubtitle¦\framesubtitle{${1:subtitle}}$0¦Subtitle of the current frame¦beamer
\framebreak¦\framebreak$0¦Break the frame into two¦beamer
\pause¦\pause$0¦Overlay: pause here¦beamer
\only¦\only<${1:2}>{${2:text}}$0¦Show content only on the given slides¦beamer
\uncover¦\uncover<${1:2->}>{${2:text}}$0¦Show content on the given slides, reserving space¦beamer
\visible¦\visible<${1:2->}>{${2:text}}$0¦Show content on the given slides, reserving space¦beamer
\invisible¦\invisible<${1:2->}>{${2:text}}$0¦Hide content on the given slides, reserving space¦beamer
\alert¦\alert<${1:2}>{${2:text}}$0¦Highlight text (optionally on given slides)¦beamer
\titlepage¦\titlepage$0¦Print the title page¦beamer
\subtitle¦\subtitle{${1:subtitle}}$0¦Subtitle for the title page¦beamer
\institute¦\institute{${1:institute}}$0¦Institute for the title page¦beamer
\logo¦\logo{${1:\includegraphics[height=1cm]{logo}}}$0¦Logo printed on every slide¦beamer
\usetheme¦\usetheme{${1:Madrid}}$0¦Choose a beamer theme¦beamer
\usecolortheme¦\usecolortheme{${1:beaver}}$0¦Choose a beamer colour theme¦beamer
\useoutertheme¦\useoutertheme{${1:infolines}}$0¦Choose a beamer outer theme¦beamer
\useinnertheme¦\useinnertheme{${1:rounded}}$0¦Choose a beamer inner theme¦beamer
\setbeamertemplate¦\setbeamertemplate{${1:navigation symbols}}{}$0¦Set a beamer template¦beamer
\setbeamercolor¦\setbeamercolor{${1:structure}}{fg=${2:blue}}$0¦Set a beamer colour¦beamer
\note¦\note{${1:speaker note}}$0¦Speaker note¦beamer
# ── Units and numbers (siunitx) ──────────────────────────────────────────────
\SI¦\SI{${1:1}}{${2:\meter}}$0¦Number with unit¦siunitx
\si¦\si{${1:\meter\per\second}}$0¦Unit only¦siunitx
\num¦\num{${1:1.23}}$0¦Formatted number¦siunitx
\qty¦\qty{${1:1}}{${2:\meter}}$0¦Quantity with unit (siunitx 3)¦siunitx
\unit¦\unit{${1:\meter}}$0¦Unit (siunitx 3)¦siunitx
\ang¦\ang{${1:30}}$0¦Angle in degrees¦siunitx
\SIrange¦\SIrange{${1:1}}{${2:2}}{${3:\meter}}$0¦Range of quantities¦siunitx
\sisetup¦\sisetup{${1:output-decimal-marker={,}}}$0¦Set siunitx options¦siunitx
# ── More document and package commands ───────────────────────────────────────
\AtBeginDocument¦\AtBeginDocument{${1:code}}$0¦Run code at the start of the document¦
\AtEndDocument¦\AtEndDocument{${1:code}}$0¦Run code at the end of the document¦
\AtBeginEnvironment¦\AtBeginEnvironment{${1:env}}{${2:code}}$0¦Run code at the start of an environment¦etoolbox
\patchcmd¦\patchcmd{${1:\command}}{${2:search}}{${3:replace}}{${4:success}}{${5:failure}}$0¦Patch the definition of a command¦etoolbox
\ifthenelse¦\ifthenelse{${1:\equal{\x}{\y}}}{${2:true}}{${3:false}}$0¦Conditional with test expressions¦ifthen
\IfFileExists¦\IfFileExists{${1:file}}{${2:found}}{${3:missing}}$0¦Test whether a file exists¦
\addcontentsline¦\addcontentsline{${1:toc}}{${2:section}}{${3:title}}$0¦Add an entry to a contents list¦
\addtocontents¦\addtocontents{${1:toc}}{${2:text}}$0¦Add raw text to a contents list¦
\markboth¦\markboth{${1:LEFT}}{${2:RIGHT}}$0¦Set both running headers¦
\markright¦\markright{${1:RIGHT}}$0¦Set the right running header¦
\thesection¦¦The number of the current section¦
\thefigure¦¦The number of the current figure¦
\thepage¦¦The current page number¦
\refname¦¦Word "References" (for localisation)¦
\bibname¦¦Word "Bibliography" (for localisation)¦
\contentsname¦¦Word "Contents" (for localisation)¦
\abstractname¦¦Word "Abstract" (for localisation)¦
\appendixname¦¦Word "Appendix" (for localisation)¦
\chaptername¦¦Word "Chapter" (for localisation)¦
\indexname¦¦Word "Index" (for localisation)¦
\DeclareGraphicsExtensions¦\DeclareGraphicsExtensions{${1:.pdf,.png,.jpg}}$0¦File types searched for images¦graphicx
\newcolumntype¦\newcolumntype{${1:L}}{>{${2:\raggedright\arraybackslash}}p{${3:3cm}}}$0¦Define a custom column type¦array
\arrayrulecolor¦\arrayrulecolor{${1:gray}}$0¦Colour of table rules¦colortbl
\ContinuedFloat¦\ContinuedFloat$0¦Continue a float under the same number¦caption
\pdfbookmark¦\pdfbookmark[${1:1}]{${2:title}}{${3:label}}$0¦Add a PDF bookmark¦hyperref
\xspace¦\xspace$0¦Add a space unless punctuation follows¦xspace
\hologo¦\hologo{${1:BibTeX}}$0¦Logo such as BibTeX or XeTeX¦hologo
\lipsum¦\lipsum[${1:1}]$0¦Lorem ipsum paragraphs¦lipsum
\blindtext¦\blindtext$0¦Dummy text paragraph¦blindtext
\newacronym¦\newacronym{${1:key}}{${2:ABBR}}{${3:full name}}$0¦Define an acronym¦glossaries
\gls¦\gls{${1:key}}$0¦Glossary term¦glossaries
\glspl¦\glspl{${1:key}}$0¦Plural glossary term¦glossaries
\acrshort¦\acrshort{${1:key}}$0¦Short form of an acronym¦glossaries
\acrlong¦\acrlong{${1:key}}$0¦Long form of an acronym¦glossaries
\acrfull¦\acrfull{${1:key}}$0¦Long form followed by the short form¦glossaries
\makeglossaries¦\makeglossaries$0¦Enable the glossaries¦glossaries
\printglossaries¦\printglossaries$0¦Print the glossaries¦glossaries
\pgfmathsetmacro¦\pgfmathsetmacro{${1:\result}}{${2:1+2}}$0¦Set a macro to a numeric expression¦pgf
\matrix¦\matrix ${1:(m)} [${2:matrix of math nodes}] {${3:A & B \\ C & D};}$0¦Matrix of nodes in TikZ¦tikz
\addplot¦\addplot[${1:blue}] {${2:x^2}};$0¦Plot a function or data¦pgfplots
\addlegendentry¦\addlegendentry{${1:label}}$0¦Legend entry for a plot¦pgfplots
\ce¦\ce{${1:H2O}}$0¦Chemical formula¦mhchem
\textbullet¦¦• — bullet¦
\textdegree¦¦° — degree sign¦textcomp
\texteuro¦¦€ — euro sign¦textcomp
\euro¦¦€ — euro sign¦eurosym
\textendash¦¦– — en dash¦
\textemdash¦¦— — em dash¦
\textquotedblleft¦¦“ — left double quotation mark¦
\textquotedblright¦¦” — right double quotation mark¦
\textquoteleft¦¦‘ — left single quotation mark¦
\textquoteright¦¦’ — right single quotation mark¦
\guillemotleft¦¦« — left guillemet¦
\guillemotright¦¦» — right guillemet¦
\ss¦¦ß — German sharp s¦
\o¦¦ø — o with stroke¦
\O¦¦Ø — capital O with stroke¦
\ae¦¦æ — ae ligature¦
\AE¦¦Æ — capital AE ligature¦
\oe¦¦œ — oe ligature¦
\OE¦¦Œ — capital OE ligature¦
\aa¦¦å — a with ring¦
\AA¦¦Å — capital A with ring¦
\l¦¦ł — l with stroke¦
\L¦¦Ł — capital L with stroke¦
\i¦¦ı — dotless i¦
\j¦¦ȷ — dotless j¦
\hfil¦¦Horizontal fill (TeX primitive)¦
\hskip¦\hskip ${1:1em}$0¦Horizontal skip (TeX primitive)¦
\vskip¦\vskip ${1:1em}$0¦Vertical skip (TeX primitive)¦
\kern¦\kern ${1:1pt}$0¦Fixed kern (TeX primitive)¦
\sloppy¦\sloppy$0¦Looser line breaking¦
\fussy¦\fussy$0¦Stricter line breaking¦
\raggedbottom¦\raggedbottom$0¦Allow variable page heights¦
\flushbottom¦\flushbottom$0¦Fixed page heights¦
\enlargethispage¦\enlargethispage{${1:\baselineskip}}$0¦Allow one more line on this page¦
\nobreak¦\nobreak$0¦Forbid a line break here¦
\protect¦\protect$0¦Protect a fragile command¦
\ignorespaces¦\ignorespaces$0¦Ignore the spaces that follow¦
\relax¦\relax$0¦Do nothing and stop expansion¦
\jobname¦¦Name of the current job, without extension¦
# ── Further text commands ────────────────────────────────────────────────────
\[¦\[ $0 \]¦Display mathematics (unnumbered)¦
\(¦\( $0 \)¦Inline mathematics¦
\endinput¦\endinput$0¦Stop reading the current file¦
\onecolumn¦\onecolumn$0¦Single-column layout¦
\twocolumn¦\twocolumn$0¦Two-column layout¦
\MakeUppercase¦\MakeUppercase{${1:text}}$0¦Convert text to uppercase¦
\MakeLowercase¦\MakeLowercase{${1:text}}$0¦Convert text to lowercase¦
\uppercase¦\uppercase{${1:text}}$0¦Convert text to uppercase (TeX primitive)¦
\lowercase¦\lowercase{${1:text}}$0¦Convert text to lowercase (TeX primitive)¦
\textbackslash¦¦\ backslash¦
\textasciitilde¦¦~ tilde¦
\textasciicircum¦¦^ circumflex¦
\textbar¦¦| vertical bar¦
\textless¦¦< less-than sign¦
\textgreater¦¦> greater-than sign¦
\texttrademark¦¦™ — trademark¦textcomp
\llap¦\llap{${1:text}}$0¦Zero-width box, text to the left¦
\rlap¦\rlap{${1:text}}$0¦Zero-width box, text to the right¦
\hbox¦\hbox{${1:text}}$0¦Horizontal box (TeX primitive)¦
\paragraph*¦\paragraph*{${1:title}}$0¦Unnumbered paragraph heading¦
\proofname¦¦Word "Proof" (amsthm)¦amsthm
\mathtoolsset¦\mathtoolsset{${1:showonlyrefs}}$0¦Set mathtools options¦mathtools
\citeyearpar¦\citeyearpar{${1:key}}$0¦Year in parentheses (natbib)¦natbib
\fullcite¦\fullcite{${1:key}}$0¦Full bibliographic reference in a footnote (biblatex)¦biblatex
\citetitle¦\citetitle{${1:key}}$0¦Title of a work (biblatex)¦biblatex
\citeauthor*¦\citeauthor*{${1:key}}$0¦Full author names (natbib star form)¦natbib
\suppressfloats¦\suppressfloats[${1:t}]$0¦Keep floats off the current page¦placeins
\reflectbox¦\reflectbox{${1:content}}$0¦Mirror a box horizontally (graphicx)¦graphicx
\rowcolors¦\rowcolors{${1:2}}{${2:gray!10}}{${3:white}}$0¦Alternate row colours (colortbl)¦colortbl
\xdefinecolor¦\xdefinecolor{${1:name}}{${2:rgb}}{${3:0,0.5,1}}$0¦Define a colour globally (xcolor)¦xcolor
\urlstyle¦\urlstyle{${1:same}}$0¦Font for URLs (url)¦url
\microtypesetup¦\microtypesetup{${1:protrusion=false}}$0¦Set microtype options¦microtype
\namecref¦\namecref{${1:key}}$0¦Type name of a label, lowercase (cleveref)¦cleveref
\cpageref¦\cpageref{${1:key}}$0¦Page reference with the type name (cleveref)¦cleveref
\onslide¦\onslide<${1:2->}>{${2:text}}$0¦Show content only on the given slides (beamer)¦beamer
\sectionpage¦\sectionpage$0¦Print a section title page (beamer)¦beamer
\setbeamercovered¦\setbeamercovered{${1:transparent}}$0¦Covered content style (beamer)¦beamer
\AtBeginSection¦\AtBeginSection[]{${1:\frame{\sectionpage}}}$0¦Code run at the start of each section (beamer)¦beamer
\numrange¦\numrange{${1:1}}{${2:2}}$0¦Range of numbers (siunitx)¦siunitx
\textquote¦\textquote{${1:text}}$0¦Inline quotation with punctuation (csquotes)¦csquotes
\todo¦\todo{${1:note}}$0¦Todo note in the margin¦todonotes
\missingfigure¦\missingfigure{${1:caption}}$0¦Placeholder for a missing figure (todonotes)¦todonotes
\newtcolorbox¦\newtcolorbox{${1:name}}{${2:colback=blue!5}}$0¦Define a coloured box (tcolorbox)¦tcolorbox
\pgfplotsset¦\pgfplotsset{${1:compat=1.18}}$0¦Global options for pgfplots¦pgfplots
\State¦\State ${1:statement}$0¦Statement in pseudocode¦algpseudocode
\Return¦\Return ${1:value}$0¦Return a value in pseudocode¦algpseudocode
\Require¦\Require ${1:input}$0¦Input of an algorithm¦algpseudocode
\Ensure¦\Ensure ${1:output}$0¦Output of an algorithm¦algpseudocode
\If¦\If{${1:condition}}⏎⇥$0⏎\EndIf¦Conditional block in pseudocode¦algpseudocode
\EndIf¦\EndIf¦End of an \If block¦algpseudocode
\For¦\For{${1:i = 1 to n}}⏎⇥$0⏎\EndFor¦Loop in pseudocode¦algpseudocode
\EndFor¦\EndFor¦End of a \For block¦algpseudocode
\While¦\While{${1:condition}}⏎⇥$0⏎\EndWhile¦While loop in pseudocode¦algpseudocode
\EndWhile¦\EndWhile¦End of a \While block¦algpseudocode
"""#

    static let mathCommandsTable = #"""
# ── Greek letters ────────────────────────────────────────────────────────────
\alpha¦¦α — alpha¦
\beta¦¦β — beta¦
\gamma¦¦γ — gamma¦
\delta¦¦δ — delta¦
\epsilon¦¦ϵ — epsilon (lunate form)¦
\varepsilon¦¦ε — epsilon (variant)¦
\zeta¦¦ζ — zeta¦
\eta¦¦η — eta¦
\theta¦¦θ — theta¦
\vartheta¦¦ϑ — theta (variant)¦
\iota¦¦ι — iota¦
\kappa¦¦κ — kappa¦
\varkappa¦¦ϰ — kappa (variant)¦amssymb
\lambda¦¦λ — lambda¦
\mu¦¦μ — mu¦
\nu¦¦ν — nu¦
\xi¦¦ξ — xi¦
\pi¦¦π — pi¦
\varpi¦¦ϖ — pi (variant)¦
\rho¦¦ρ — rho¦
\varrho¦¦ϱ — rho (variant)¦
\sigma¦¦σ — sigma¦
\varsigma¦¦ς — final sigma¦
\tau¦¦τ — tau¦
\upsilon¦¦υ — upsilon¦
\phi¦¦ϕ — phi (stroked form)¦
\varphi¦¦φ — phi (variant)¦
\chi¦¦χ — chi¦
\psi¦¦ψ — psi¦
\omega¦¦ω — omega¦
\digamma¦¦ϝ — digamma¦
\Gamma¦¦Γ — capital gamma¦
\Delta¦¦Δ — capital delta¦
\Theta¦¦Θ — capital theta¦
\Lambda¦¦Λ — capital lambda¦
\Xi¦¦Ξ — capital xi¦
\Pi¦¦Π — capital pi¦
\Sigma¦¦Σ — capital sigma¦
\Upsilon¦¦Υ — capital upsilon¦
\Phi¦¦Φ — capital phi¦
\Psi¦¦Ψ — capital psi¦
\Omega¦¦Ω — capital omega¦
# ── Binary operators ─────────────────────────────────────────────────────────
\pm¦¦± — plus or minus¦
\mp¦¦∓ — minus or plus¦
\times¦¦× — times¦
\div¦¦÷ — division¦
\cdot¦¦⋅ — centred dot¦
\cdotp¦¦· — centred dot (punctuation)¦
\ast¦¦∗ — asterisk operator¦
\star¦¦⋆ — star operator¦
\circ¦¦∘ — composition¦
\bullet¦¦• — bullet¦
\oplus¦¦⊕ — direct sum¦
\ominus¦¦⊖ — circled minus¦
\otimes¦¦⊗ — tensor product¦
\oslash¦¦⊘ — circled slash¦
\odot¦¦⊙ — circled dot¦
\bigcirc¦¦◯ — large circle¦
\wedge¦¦∧ — wedge (and)¦
\vee¦¦∨ — vee (or)¦
\cap¦¦∩ — intersection¦
\cup¦¦∪ — union¦
\uplus¦¦⊎ — multiset union¦
\setminus¦¦∖ — set difference¦
\smallsetminus¦¦∖ — small set difference¦amssymb
\sqcup¦¦⊔ — square union¦
\sqcap¦¦⊓ — square intersection¦
\amalg¦¦∐ — amalgamated product¦
\triangleleft¦¦◁ — triangle left¦
\triangleright¦¦▷ — triangle right¦
\bigtriangleup¦¦△ — big triangle up¦
\bigtriangledown¦¦▽ — big triangle down¦
\lhd¦¦⊲ — normal subgroup (left)¦amssymb
\rhd¦¦⊳ — normal subgroup (right)¦amssymb
\unlhd¦¦⊴ — normal subgroup or equal (left)¦amssymb
\unrhd¦¦⊵ — normal subgroup or equal (right)¦amssymb
\dagger¦¦† — dagger¦
\ddagger¦¦‡ — double dagger¦
\wr¦¦≀ — wreath product¦
\diamond¦¦⋄ — diamond operator¦
\centerdot¦¦⋅ — centred dot¦amssymb
\divideontimes¦¦⋇ — division on times¦amssymb
\ltimes¦¦⋉ — semidirect product (left)¦amssymb
\rtimes¦¦⋊ — semidirect product (right)¦amssymb
\leftthreetimes¦¦⋋ — left semidirect product¦amssymb
\rightthreetimes¦¦⋌ — right semidirect product¦amssymb
\boxplus¦¦⊞ — boxed plus¦amssymb
\boxminus¦¦⊟ — boxed minus¦amssymb
\boxtimes¦¦⊠ — boxed times¦amssymb
\boxdot¦¦⊡ — boxed dot¦amssymb
\circledast¦¦⊛ — circled asterisk¦amssymb
\circledcirc¦¦⊚ — circled circle¦amssymb
\circleddash¦¦⊝ — circled dash¦amssymb
\intercal¦¦⊺ — intercal¦amssymb
\veebar¦¦⊻ — exclusive or¦amssymb
\barwedge¦¦⊼ — nand¦amssymb
\doublecap¦¦⋒ — double intersection¦amssymb
\doublecup¦¦⋓ — double union¦amssymb
\pitchfork¦¦⋔ — pitchfork¦amssymb
\bmod¦¦mod — binary modulus¦
\pmod¦\pmod{${1:n}}$0¦Parenthesised modulus (mod n)¦amsmath
\mod¦¦Modulus, as in a \mod n¦amsmath
# ── Relations ────────────────────────────────────────────────────────────────
\leq¦¦≤ — less than or equal¦
\le¦¦≤ — less than or equal (short)¦
\geq¦¦≥ — greater than or equal¦
\ge¦¦≥ — greater than or equal (short)¦
\neq¦¦≠ — not equal¦
\ne¦¦≠ — not equal (short)¦
\equiv¦¦≡ — equivalent¦
\sim¦¦∼ — similar¦
\simeq¦¦≃ — similar or equal¦
\approx¦¦≈ — approximately equal¦
\cong¦¦≅ — congruent or isomorphic¦
\propto¦¦∝ — proportional to¦
\prec¦¦≺ — precedes¦
\succ¦¦≻ — succeeds¦
\preceq¦¦⪯ — precedes or equal¦
\succeq¦¦⪰ — succeeds or equal¦
\precsim¦¦≾ — precedes or similar¦amssymb
\succsim¦¦≿ — succeeds or similar¦amssymb
\preccurlyeq¦¦≼ — precedes, curly equal¦amssymb
\succcurlyeq¦¦≽ — succeeds, curly equal¦amssymb
\ll¦¦≪ — much less than¦
\gg¦¦≫ — much greater than¦
\subset¦¦⊂ — subset¦
\supset¦¦⊃ — superset¦
\subseteq¦¦⊆ — subset or equal¦
\supseteq¦¦⊇ — superset or equal¦
\subsetneq¦¦⊊ — proper subset¦amssymb
\supsetneq¦¦⊋ — proper superset¦amssymb
\subseteqq¦¦⫅ — subset of double equal¦amssymb
\supseteqq¦¦⫆ — superset of double equal¦amssymb
\Subset¦¦⋐ — double subset¦amssymb
\Supset¦¦⋑ — double superset¦amssymb
\sqsubset¦¦⊏ — square subset¦amssymb
\sqsupset¦¦⊐ — square superset¦amssymb
\sqsubseteq¦¦⊑ — square subset or equal¦
\sqsupseteq¦¦⊒ — square superset or equal¦
\leqslant¦¦⩽ — less than or slanted equal¦amssymb
\geqslant¦¦⩾ — greater than or slanted equal¦amssymb
\leqq¦¦≦ — less than over equal¦amssymb
\geqq¦¦≧ — greater than over equal¦amssymb
\lesssim¦¦≲ — less than or similar¦amssymb
\gtrsim¦¦≳ — greater than or similar¦amssymb
\lessapprox¦¦⪅ — less than or approximately¦amssymb
\gtrapprox¦¦⪆ — greater than or approximately¦amssymb
\lneq¦¦⪇ — less than and not equal¦amssymb
\gneq¦¦⪈ — greater than and not equal¦amssymb
\in¦¦∈ — element of¦
\ni¦¦∋ — contains as element¦
\notin¦¦∉ — not an element of¦
\perp¦¦⊥ — perpendicular¦
\parallel¦¦∥ — parallel¦
\mid¦¦∣ — divides or such that (relation)¦
\nmid¦¦∤ — does not divide¦amssymb
\shortmid¦¦∣ — short mid¦amssymb
\shortparallel¦¦∥ — short parallel¦amssymb
\nparallel¦¦∦ — not parallel¦amssymb
\vdash¦¦⊢ — turnstile¦
\dashv¦¦⊣ — reverse turnstile¦
\models¦¦⊨ — models¦
\vDash¦¦⊨ — double turnstile (models)¦amssymb
\Vdash¦¦⊩ — forces¦amssymb
\Vvdash¦¦⊪ — triple turnstile¦amssymb
\nvdash¦¦⊬ — does not prove¦amssymb
\nvDash¦¦⊭ — does not model¦amssymb
\nVdash¦¦⊮ — does not force¦amssymb
\doteq¦¦≐ — approaches the limit¦
\asymp¦¦≍ — asymptotically equivalent¦
\bowtie¦¦⋈ — bowtie¦
\smile¦¦⌣ — smile¦
\frown¦¦⌢ — frown¦
\between¦¦≬ — between¦amssymb
\backsim¦¦∽ — reversed tilde¦amssymb
\thicksim¦¦∼ — thick similar¦amssymb
\thickapprox¦¦≈ — thick approximately equal¦amssymb
\approxeq¦¦≊ — approximately equal or equal¦amssymb
\eqcirc¦¦≖ — ring in equal to¦amssymb
\circeq¦¦≗ — ring equal to¦amssymb
\triangleq¦¦≜ — delta equal to¦amssymb
\bumpeq¦¦≏ — bumpy equals¦amssymb
\Bumpeq¦¦≎ — double bumpy equals¦amssymb
\doteqdot¦¦≑ — geometrically equal¦amssymb
\risingdotseq¦¦≓ — image of or approximately equal¦amssymb
\fallingdotseq¦¦≒ — approximately equal to or image of¦amssymb
\therefore¦¦∴ — therefore¦amssymb
\because¦¦∵ — because¦amssymb
\varpropto¦¦∝ — proportional (variant)¦amssymb
\nless¦¦≮ — not less than¦amssymb
\ngtr¦¦≯ — not greater than¦amssymb
\nleq¦¦≰ — not less than or equal¦amssymb
\ngeq¦¦≱ — not greater than or equal¦amssymb
\nleqslant¦¦not slanted less than or equal¦amssymb
\ngeqslant¦¦not slanted greater than or equal¦amssymb
\nsim¦¦≁ — not similar¦amssymb
\ncong¦¦≇ — not congruent¦amssymb
\napprox¦¦≉ — not approximately equal¦amssymb
\nprec¦¦⊀ — does not precede¦amssymb
\nsucc¦¦⊁ — does not succeed¦amssymb
\nsubseteq¦¦⊈ — not subset or equal¦amssymb
\nsupseteq¦¦⊉ — not superset or equal¦amssymb
\nsubset¦¦⊄ — not subset¦amssymb
\nsupset¦¦⊅ — not superset¦amssymb
\ntriangleleft¦¦⋪ — not normal subgroup (left)¦amssymb
\ntriangleright¦¦⋫ — not normal subgroup (right)¦amssymb
\ntrianglelefteq¦¦⋬ — not normal subgroup or equal (left)¦amssymb
\ntrianglerighteq¦¦⋭ — not normal subgroup or equal (right)¦amssymb
\nexists¦¦∄ — there does not exist¦amssymb
\not¦¦negation slash (\not\in gives ∉)¦
# ── Arrows ───────────────────────────────────────────────────────────────────
\leftarrow¦¦← — left arrow¦
\gets¦¦← — gets (left arrow)¦
\rightarrow¦¦→ — right arrow¦
\to¦¦→ — to (right arrow)¦
\leftrightarrow¦¦↔ — left-right arrow¦
\Leftarrow¦¦⇐ — implied by¦
\Rightarrow¦¦⇒ — implies¦
\Leftrightarrow¦¦⇔ — if and only if (double arrow)¦
\iff¦¦⟺ — if and only if¦
\implies¦¦⟹ — implies¦
\longleftarrow¦¦⟵ — long left arrow¦
\longrightarrow¦¦⟶ — long right arrow¦
\longleftrightarrow¦¦⟷ — long left-right arrow¦
\Longleftarrow¦¦⟸ — long implied by¦
\Longrightarrow¦¦⟹ — long implies¦
\Longleftrightarrow¦¦⟺ — long if and only if¦
\mapsto¦¦↦ — maps to¦
\longmapsto¦¦⟼ — long maps to¦
\hookleftarrow¦¦↩ — hook left arrow¦
\hookrightarrow¦¦↪ — hook right arrow¦
\rightarrowtail¦¦↣ — right arrow with tail¦amssymb
\leftarrowtail¦¦↢ — left arrow with tail¦amssymb
\twoheadrightarrow¦¦↠ — two-headed right arrow¦amssymb
\twoheadleftarrow¦¦↞ — two-headed left arrow¦amssymb
\uparrow¦¦↑ — up arrow¦
\downarrow¦¦↓ — down arrow¦
\updownarrow¦¦↕ — up-down arrow¦
\Uparrow¦¦⇑ — double up arrow¦
\Downarrow¦¦⇓ — double down arrow¦
\Updownarrow¦¦⇕ — double up-down arrow¦
\nearrow¦¦↗ — north-east arrow¦
\searrow¦¦↘ — south-east arrow¦
\swarrow¦¦↙ — south-west arrow¦
\nwarrow¦¦↖ — north-west arrow¦
\leftharpoonup¦¦↼ — left harpoon up¦
\leftharpoondown¦¦↽ — left harpoon down¦
\rightharpoonup¦¦⇀ — right harpoon up¦
\rightharpoondown¦¦⇁ — right harpoon down¦
\rightleftharpoons¦¦⇌ — right over left harpoons¦
\leftrightharpoons¦¦⇋ — left over right harpoons¦amssymb
\rightsquigarrow¦¦⇝ — squiggly right arrow¦amssymb
\leadsto¦¦⇝ — leads to (squiggly arrow)¦amssymb
\dashrightarrow¦¦⇢ — dashed right arrow¦amssymb
\dashleftarrow¦¦⇠ — dashed left arrow¦amssymb
\looparrowright¦¦↬ — loop right arrow¦amssymb
\looparrowleft¦¦↫ — loop left arrow¦amssymb
\curvearrowright¦¦↷ — curved right arrow¦amssymb
\curvearrowleft¦¦↶ — curved left arrow¦amssymb
\circlearrowright¦¦↻ — clockwise circle arrow¦amssymb
\circlearrowleft¦¦↺ — anticlockwise circle arrow¦amssymb
\Rrightarrow¦¦⇛ — triple right arrow¦amssymb
\Lleftarrow¦¦⇚ — triple left arrow¦amssymb
\rightrightarrows¦¦⇉ — two right arrows¦amssymb
\leftleftarrows¦¦⇇ — two left arrows¦amssymb
\rightleftarrows¦¦⇄ — right over left arrows¦amssymb
\leftrightarrows¦¦⇆ — left over right arrows¦amssymb
\upuparrows¦¦⇈ — two up arrows¦amssymb
\downdownarrows¦¦⇊ — two down arrows¦amssymb
\multimap¦¦⊸ — multimap (linear implication)¦amssymb
\nrightarrow¦¦↛ — does not go to the right¦amssymb
\nleftarrow¦¦↚ — does not go to the left¦amssymb
\nleftrightarrow¦¦↮ — not left-right arrow¦amssymb
\nRightarrow¦¦⇏ — does not imply¦amssymb
\nLeftarrow¦¦⇍ — not implied by¦amssymb
\nLeftrightarrow¦¦⇎ — not if and only if¦amssymb
\xrightarrow¦\xrightarrow[${1:below}]{${2:above}}$0¦Long right arrow with labels¦amsmath
\xleftarrow¦\xleftarrow[${1:below}]{${2:above}}$0¦Long left arrow with labels¦amsmath
\xleftrightarrow¦\xleftrightarrow{${1:above}}$0¦Long left-right arrow with a label¦mathtools
\xhookrightarrow¦\xhookrightarrow{${1:above}}$0¦Long hook right arrow with a label¦mathtools
\xmapsto¦\xmapsto{${1:above}}$0¦Long maps-to arrow with a label¦mathtools
# ── Large operators ──────────────────────────────────────────────────────────
\sum¦\sum_{${1:i=1}}^{${2:n}} $0¦Summation¦
\prod¦\prod_{${1:i=1}}^{${2:n}} $0¦Product¦
\coprod¦¦∐ — coproduct¦
\int¦\int_{${1:a}}^{${2:b}} $0¦Integral¦
\iint¦¦∬ — double integral¦amsmath
\iiint¦¦∭ — triple integral¦amsmath
\iiiint¦¦⨌ — quadruple integral¦amsmath
\oint¦¦∮ — contour integral¦
\oiint¦¦∯ — surface integral¦amsmath
\bigcup¦¦⋃ — big union¦
\bigcap¦¦⋂ — big intersection¦
\bigsqcup¦¦⨆ — big square union¦
\bigvee¦¦⋁ — big or¦
\bigwedge¦¦⋀ — big and¦
\biguplus¦¦⨄ — big multiset union¦
\bigoplus¦¦⨁ — big direct sum¦
\bigotimes¦¦⨂ — big tensor product¦
\bigodot¦¦⨀ — big circled dot¦
\limits¦¦Limits above and below the operator¦
\nolimits¦¦Limits beside the operator¦
\displaylimits¦¦Limits above and below in display style¦
\lim¦\lim_{${1:n \to \infty}} $0¦Limit¦
\limsup¦¦lim sup¦
\liminf¦¦lim inf¦
\varliminf¦¦lim inf (variant)¦amsmath
\varlimsup¦¦lim sup (variant)¦amsmath
\varprojlim¦¦lim← — inverse limit¦amsmath
\varinjlim¦¦lim→ — direct limit¦amsmath
\projlim¦¦projective limit¦amsmath
\injlim¦¦injective limit¦amsmath
\directlim¦¦direct limit¦amsmath
# ── Functions ────────────────────────────────────────────────────────────────
\sin¦¦sin — sine¦
\cos¦¦cos — cosine¦
\tan¦¦tan — tangent¦
\cot¦¦cot — cotangent¦
\sec¦¦sec — secant¦
\csc¦¦csc — cosecant¦
\arcsin¦¦arcsin — inverse sine¦
\arccos¦¦arccos — inverse cosine¦
\arctan¦¦arctan — inverse tangent¦
\sinh¦¦sinh — hyperbolic sine¦
\cosh¦¦cosh — hyperbolic cosine¦
\tanh¦¦tanh — hyperbolic tangent¦
\coth¦¦coth — hyperbolic cotangent¦
\exp¦¦exp — exponential¦
\log¦¦log — logarithm¦
\ln¦¦ln — natural logarithm¦
\lg¦¦lg — logarithm base 10¦
\det¦¦det — determinant¦
\dim¦¦dim — dimension¦
\ker¦¦ker — kernel¦
\deg¦¦deg — degree¦
\hom¦¦hom — homomorphisms¦
\arg¦¦arg — argument¦
\max¦¦max — maximum¦
\min¦¦min — minimum¦
\sup¦¦sup — supremum¦
\inf¦¦inf — infimum¦
\gcd¦¦gcd — greatest common divisor¦
\Pr¦¦Pr — probability¦
\Re¦¦ℜ — real part¦
\Im¦¦ℑ — imaginary part¦
\operatorname¦\operatorname{${1:name}}$0¦Upright operator name¦amsmath
# ── Accents and decorations ──────────────────────────────────────────────────
\hat¦\hat{${1:x}}$0¦Hat accent (ˆ)¦
\widehat¦\widehat{${1:x}}$0¦Wide hat accent¦
\bar¦\bar{${1:x}}$0¦Bar accent (macron)¦
\overline¦\overline{${1:x}}$0¦Overline (closure or conjugate)¦
\tilde¦\tilde{${1:x}}$0¦Tilde accent¦
\widetilde¦\widetilde{${1:x}}$0¦Wide tilde accent¦
\vec¦\vec{${1:x}}$0¦Vector arrow accent¦
\overrightarrow¦\overrightarrow{${1:AB}}$0¦Wide right arrow above¦
\overleftarrow¦\overleftarrow{${1:AB}}$0¦Wide left arrow above¦
\dot¦\dot{${1:x}}$0¦Dot accent (time derivative)¦
\ddot¦\ddot{${1:x}}$0¦Double dot accent¦
\dddot¦\dddot{${1:x}}$0¦Triple dot accent¦amsmath
\check¦\check{${1:x}}$0¦Check accent¦
\breve¦\breve{${1:x}}$0¦Breve accent¦
\acute¦\acute{${1:x}}$0¦Acute accent¦
\grave¦\grave{${1:x}}$0¦Grave accent¦
\underline¦\underline{${1:x}}$0¦Underline¦
\overbrace¦\overbrace{${1:x}}^{${2:label}}$0¦Brace above a formula¦amsmath
\underbrace¦\underbrace{${1:x}}_{${2:label}}$0¦Brace below a formula¦amsmath
# ── Fonts in math ────────────────────────────────────────────────────────────
\mathbb¦\mathbb{${1:R}}$0¦Blackboard bold¦amssymb
\Bbbk¦¦𝕜 — blackboard bold k¦amssymb
\mathcal¦\mathcal{${1:A}}$0¦Calligraphic letters¦
\mathscr¦\mathscr{${1:A}}$0¦Script letters¦mathrsfs
\mathfrak¦\mathfrak{${1:g}}$0¦Fraktur letters¦amssymb
\mathrm¦\mathrm{${1:text}}$0¦Upright roman¦
\mathbf¦\mathbf{${1:v}}$0¦Bold¦
\mathsf¦\mathsf{${1:text}}$0¦Sans-serif¦
\mathit¦\mathit{${1:text}}$0¦Italic¦
\mathtt¦\mathtt{${1:text}}$0¦Typewriter¦
\mathnormal¦\mathnormal{${1:text}}$0¦Default math italic¦
\boldsymbol¦\boldsymbol{${1:v}}$0¦Bold symbols, including Greek¦amsmath
\bm¦\bm{${1:v}}$0¦Bold math symbols¦bm
\text¦\text{${1:text}}$0¦Text inside a formula¦amsmath
\intertext¦\intertext{${1:text}}$0¦Text between aligned rows¦amsmath
\tag¦\tag{${1:label}}$0¦Custom equation tag¦amsmath
\tag*¦\tag*{${1:label}}$0¦Custom tag without parentheses¦amsmath
\notag¦\notag$0¦Suppress the equation number¦amsmath
\nonumber¦\nonumber$0¦Suppress the equation number¦amsmath
# ── Fractions, roots, binomials, stacking ────────────────────────────────────
\frac¦\frac{${1:a}}{${2:b}}$0¦Fraction¦
\dfrac¦\dfrac{${1:a}}{${2:b}}$0¦Display-size fraction¦amsmath
\tfrac¦\tfrac{${1:a}}{${2:b}}$0¦Text-size fraction¦amsmath
\cfrac¦\cfrac{${1:a}}{${2:b}}$0¦Continued fraction¦amsmath
\sqrt¦\sqrt{${1:x}}$0¦Square root¦
\binom¦\binom{${1:n}}{${2:k}}$0¦Binomial coefficient¦amsmath
\dbinom¦\dbinom{${1:n}}{${2:k}}$0¦Display-size binomial¦amsmath
\tbinom¦\tbinom{${1:n}}{${2:k}}$0¦Text-size binomial¦amsmath
\stackrel¦\stackrel{${1:above}}{${2:rel}}$0¦Relation with text above¦
\overset¦\overset{${1:above}}{${2:base}}$0¦Text above a symbol¦amsmath
\underset¦\underset{${1:below}}{${2:base}}$0¦Text below a symbol¦amsmath
\substack¦\substack{${1:a} \\ ${2:b}}$0¦Stacked subscript or superscript¦amsmath
\smash¦\smash{${1:x}}$0¦Zero-height box¦
\mathstrut¦¦Invisible strut of standard height¦
\phantom¦\phantom{${1:x}}$0¦Invisible box of the same size¦
\vphantom¦\vphantom{${1:x}}$0¦Invisible box with the height of its contents¦
\hphantom¦\hphantom{${1:x}}$0¦Invisible box with the width of its contents¦amsmath
\mathbin¦\mathbin{${1:x}}$0¦Treat as a binary operator¦
\mathrel¦\mathrel{${1:x}}$0¦Treat as a relation¦
\mathop¦\mathop{${1:x}}$0¦Treat as a large operator¦
\mathord¦\mathord{${1:x}}$0¦Treat as an ordinary symbol¦
\mathpunct¦\mathpunct{${1:x}}$0¦Treat as punctuation¦
\mathopen¦\mathopen{${1:x}}$0¦Treat as an opening delimiter¦
\mathclose¦\mathclose{${1:x}}$0¦Treat as a closing delimiter¦
\mathinner¦\mathinner{${1:x}}$0¦Treat as an inner atom¦
\eqqcolon¦¦≕ — equals colon¦mathtools
\coloneqq¦¦≔ — colon equals¦mathtools
\Coloneqq¦¦⩴ — double colon equals¦mathtools
\coloneq¦¦≔ — colon equals (alias)¦mathtools
\vcentcolon¦¦: — vertically centred colon¦mathtools
\colon¦¦: — colon¦
# ── Delimiters ───────────────────────────────────────────────────────────────
\left¦\left(${1:x}\right)$0¦Stretchy left delimiter (pair with \right)¦
\right¦¦Stretchy right delimiter¦
\middle¦¦Stretchy middle delimiter inside \left...\right¦
\bigl¦¦Larger left delimiter¦
\bigr¦¦Larger right delimiter¦
\Bigl¦¦Even larger left delimiter¦
\Bigr¦¦Even larger right delimiter¦
\biggl¦¦Much larger left delimiter¦
\biggr¦¦Much larger right delimiter¦
\Biggl¦¦Largest left delimiter¦
\Biggr¦¦Largest right delimiter¦
\langle¦¦⟨ — left angle bracket¦
\rangle¦¦⟩ — right angle bracket¦
\lvert¦¦| — left vertical bar (absolute value)¦amsmath
\rvert¦¦| — right vertical bar¦amsmath
\lVert¦¦‖ — left double bar (norm)¦amsmath
\rVert¦¦‖ — right double bar (norm)¦amsmath
\vert¦¦| — vertical bar¦
\Vert¦¦‖ — double vertical bar¦
\|¦¦‖ — double bar (norm)¦
\lfloor¦¦⌊ — left floor¦
\rfloor¦¦⌋ — right floor¦
\lceil¦¦⌈ — left ceiling¦
\rceil¦¦⌉ — right ceiling¦
\{¦¦{ — left brace¦
\}¦¦} — right brace¦
\lbrace¦¦{ — left brace (long name)¦
\rbrace¦¦} — right brace (long name)¦
\lbrack¦¦[ — left bracket (long name)¦
\rbrack¦¦] — right bracket (long name)¦
\ulcorner¦¦⌜ — top-left corner¦amssymb
\urcorner¦¦⌝ — top-right corner¦amssymb
\llcorner¦¦⌞ — bottom-left corner¦amssymb
\lrcorner¦¦⌟ — bottom-right corner¦amssymb
# ── Dots, primes and spacing ─────────────────────────────────────────────────
\dots¦¦… — ellipsis on the baseline¦
\cdots¦¦⋯ — centred ellipsis¦
\ldots¦¦… — low ellipsis¦
\vdots¦¦⋮ — vertical ellipsis¦
\ddots¦¦⋱ — diagonal ellipsis¦
\iddots¦¦⋰ — diagonal ellipsis (up-right)¦amsmath
\prime¦¦′ — prime¦
\backprime¦¦‵ — reverse prime¦amssymb
\displaystyle¦¦Display style¦
\textstyle¦¦Text style¦
\scriptstyle¦¦Script style¦
\scriptscriptstyle¦¦Script-script style¦
\,¦¦Thin space¦
\:¦¦Medium space¦
\;¦¦Thick space¦
\!¦¦Negative thin space¦
\quad¦¦Space of one em¦
\qquad¦¦Space of two em¦
\mspace¦\mspace{${1:3mu}}$0¦Math space of a given length¦
# ── Logic, sets and geometry ─────────────────────────────────────────────────
\forall¦¦∀ — for all¦
\exists¦¦∃ — there exists¦
\neg¦¦¬ — negation¦
\lnot¦¦¬ — negation (long name)¦
\land¦¦∧ — logical and¦
\lor¦¦∨ — logical or¦
\surd¦¦√ — square root sign¦
\angle¦¦∠ — angle¦
\measuredangle¦¦∡ — measured angle¦amssymb
\sphericalangle¦¦∢ — spherical angle¦amssymb
\triangle¦¦△ — triangle¦
\square¦¦□ — square¦amssymb
\Box¦¦□ — box¦amssymb
\blacksquare¦¦■ — filled square (end of proof)¦amssymb
\Diamond¦¦◇ — diamond¦amssymb
\lozenge¦¦◊ — lozenge¦amssymb
\blacklozenge¦¦⧫ — filled lozenge¦amssymb
\blacktriangle¦¦▲ — filled triangle¦amssymb
\blacktriangledown¦¦▼ — filled down triangle¦amssymb
\bigstar¦¦★ — large star¦amssymb
\checkmark¦¦✓ — check mark¦amssymb
\maltese¦¦✠ — Maltese cross¦amssymb
\complement¦¦∁ — complement¦amssymb
\emptyset¦¦∅ — empty set¦
\varnothing¦¦∅ — empty set (variant)¦amssymb
# ── Miscellaneous symbols ────────────────────────────────────────────────────
\infty¦¦∞ — infinity¦
\aleph¦¦ℵ — aleph¦
\beth¦¦ℶ — beth¦amssymb
\gimel¦¦ℷ — gimel¦amssymb
\daleth¦¦ℸ — daleth¦amssymb
\hbar¦¦ℏ — h-bar (reduced Planck constant)¦
\hslash¦¦ℏ — h-slash¦amssymb
\ell¦¦ℓ — script l¦
\wp¦¦℘ — Weierstrass p¦
\nabla¦¦∇ — nabla (gradient)¦
\partial¦¦∂ — partial derivative¦
\top¦¦⊤ — top (true)¦
\bot¦¦⊥ — bottom (false)¦
\imath¦¦ı — dotless i¦
\jmath¦¦ȷ — dotless j¦
\flat¦¦♭ — flat¦
\natural¦¦♮ — natural¦
\sharp¦¦♯ — sharp¦
\clubsuit¦¦♣ — club suit¦amssymb
\diamondsuit¦¦♢ — diamond suit¦amssymb
\heartsuit¦¦♡ — heart suit¦amssymb
\spadesuit¦¦♠ — spade suit¦amssymb
\Finv¦¦Ⅎ — turned capital F¦amssymb
\Game¦¦⅁ — turned capital G¦amssymb
\mho¦¦℧ — inverted ohm¦amssymb
\eth¦¦ð — eth¦amssymb
\backepsilon¦¦϶ — reversed epsilon¦amssymb
\circledS¦¦Ⓢ — circled S¦amssymb
\vartriangle¦¦△ — variant triangle¦amssymb
\vartriangleleft¦¦⊲ — variant triangle left¦amssymb
\vartriangleright¦¦⊳ — variant triangle right¦amssymb
\trianglelefteq¦¦⊴ — triangle left or equal¦amssymb
\trianglerighteq¦¦⊵ — triangle right or equal¦amssymb
\lll¦¦⋘ — very much less than¦amssymb
\ggg¦¦⋙ — very much greater than¦amssymb
\lessdot¦¦⋖ — less than with dot¦amssymb
\gtrdot¦¦⋗ — greater than with dot¦amssymb
\dotplus¦¦∔ — dot plus¦amssymb
\Join¦¦⋈ — join¦
\smallfrown¦¦⌢ — small frown¦amssymb
\smallsmile¦¦⌣ — small smile¦amssymb
\Cup¦¦⋓ — double union¦amssymb
\Cap¦¦⋒ — double intersection¦amssymb
\subsetneqq¦¦⫋ — proper subset of double equal¦amssymb
\supsetneqq¦¦⫌ — proper superset of double equal¦amssymb
\lnsim¦¦⋦ — less than but not similar¦amssymb
\gnsim¦¦⋧ — greater than but not similar¦amssymb
"""#
}
