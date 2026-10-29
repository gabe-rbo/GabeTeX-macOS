// Common LaTeX packages (name¦detail). Format: see CompletionCatalog.swift.

extension CompletionCatalog {
    static let packagesTable = #"""
# ── Mathematics and symbols ──────────────────────────────────────────────────
amsmath¦AMS mathematical facilities: align, cases, matrices, \text, \eqref
amssymb¦AMS symbols: blackboard bold, extra relations and arrows
amsfonts¦AMS fonts: blackboard bold and Fraktur letters
amsthm¦Theorem environments and the proof environment
amscd¦Commutative diagrams with the CD environment
mathtools¦Extensions to amsmath: paired delimiters, colon equalities, dcases
mathrsfs¦Script letters with \mathscr
euscript¦Euler script letters with \mathscr
stmaryrd¦St Mary's Road symbols
esint¦Extra integral signs
bigints¦Integral signs of varying size
bbm¦Blackboard bold 1 and small letters with \mathbbm
bbold¦Blackboard bold 1 and small letters
dsfont¦Double-stroke font with \mathds
upgreek¦Upright Greek letters
bm¦Bold math symbols with \bm
commath¦Shortcuts for differentials and absolute values
esdiff¦Shortcuts for derivatives
physics¦Shortcuts for physics notation: vectors, derivatives, bra-ket
braket¦Bra-ket and set notation
tensor¦Index notation with sub- and superscripts
esvect¦Vector arrows with \vv
mathdots¦Diagonal and vertical dots in matrices
nicematrix¦Matrices and tables with TikZ-style rules
arydshln¦Dashed rules in arrays and matrices
blkarray¦Matrices with block labels
extarrows¦Extensible arrows with labels
empheq¦Boxed or framed equations
cancel¦Cancelling terms in formulae
nicefrac¦Compact fractions
xfrac¦Slanted fractions
unicode-math¦OpenType maths for XeLaTeX and LuaLaTeX
wasysym¦Assorted symbols: smiley, astronomy, and others
textcomp¦Text-mode symbols: degree, euro, bullet
gensymb¦Degree and related symbols in text and math
eurosym¦Euro sign
marvosym¦Miscellaneous symbols
pifont¦Pi symbols and dingbats
bbding¦Dingbat symbols
fontawesome5¦Font Awesome 5 icons
hhline¦Horizontal rules in tables with double lines
# ── Fonts and encodings ──────────────────────────────────────────────────────
inputenc¦Input encoding (UTF-8 is the default since 2018)
fontenc¦Output font encoding (use T1)
lmodern¦Latin Modern fonts, scalable and T1 encoded
cm-super¦Scalable Computer Modern fonts, T1 encoded
microtype¦Micro-typography: protrusion and font expansion
mathpazo¦Palatino text font with matching math
mathptmx¦Times text font with matching math
newtxtext¦Times-like text font (newtx family)
newtxmath¦Times-like math font (newtx family)
txfonts¦Times-like text and math fonts
kpfonts¦Text and math fonts with many weights
fourier¦Utopia text font with matching math
times¦Times Roman text font
helvet¦Helvetica as the sans-serif font
courier¦Courier as the typewriter font
palatino¦Palatino text font
charter¦Charter text font
inconsolata¦Monospaced font for code and listings
beramono¦Bera Mono typewriter font
fontspec¦System OpenType fonts for XeLaTeX and LuaLaTeX
# ── Languages, quotes and programming ────────────────────────────────────────
babel¦Language support: hyphenation and localised text (\selectlanguage)
polyglossia¦Multilingual typesetting for XeLaTeX and LuaLaTeX
csquotes¦Context-sensitive quotation marks (\enquote)
hyphenat¦Extra hyphenation control
iftex¦Detect the TeX engine in use
etoolbox¦Patch and program toolbox
xparse¦Argument parsing for document commands
expl3¦LaTeX3 programming layer
xstring¦String manipulation
xkeyval¦Key-value option interface
kvoptions¦Key-value package options
xspace¦Automatic spacing after macros
calc¦Arithmetic with lengths
ifthen¦Conditionals with \ifthenelse
printlen¦Print lengths in other units
environ¦Capture an environment body as an argument
trimspaces¦Trim leading and trailing spaces
xcolor¦Colours in many models, with named colours
letltxmacro¦Copy macros safely
# ── Page layout and typography ───────────────────────────────────────────────
geometry¦Page dimensions and margins
fancyhdr¦Custom headers and footers
titlesec¦Format section headings
titling¦Customise \title, \author and \date
titletoc¦Format table of contents entries
titleps¦Page styles with flexible headers and footers
tocloft¦Control lists of figures, tables and contents
tocbibind¦Add contents, bibliography and index to the contents
setspace¦Line spacing for documents
parskip¦Paragraph spacing instead of indentation
indentfirst¦Indent the first paragraph after a heading
multicol¦Several columns of text
enumitem¦Customise list layout and labels
ragged2e¦Justified or ragged text with extra options
changepage¦Change margins locally (adjustwidth)
afterpage¦Run commands after the current page
lastpage¦Reference the total number of pages
footmisc¦Footnote layout options
ulem¦Underline and strikethrough that break lines
soul¦Letterspacing and highlighting
lineno¦Line numbers
chngcntr¦Change counter reset rules
remreset¦Stop counters from resetting
appendix¦Appendix formatting
hologo¦Logos: LaTeX, BibTeX, TeX
lipsum¦Lorem ipsum placeholder text
blindtext¦Dummy text blocks
datetime2¦Date and time formatting
todonotes¦Todo notes in the margin
showkeys¦Show labels in the margin while drafting
varioref¦Context-aware page references
xr¦References to labels in external documents
xr-hyper¦External references with hyperlinks
background¦Background images and watermarks
draftwatermark¦Draft watermark on pages
eso-pic¦Add content to every page
textpos¦Absolute positioning of text blocks
varwidth¦Boxes with a maximum width
lettrine¦Drop capitals
needspace¦Start a new page if not enough space remains
scrlayer-scrpage¦Page headers and footers (KOMA-Script)
scrextend¦Extend KOMA-Script options to other parts
# ── Hyperlinks, references and bibliography ──────────────────────────────────
hyperref¦Hyperlinks, PDF metadata and bookmarks
bookmark¦Improved PDF bookmarks (with hyperref)
url¦Typeset URLs and e-mail addresses
xurl¦URLs that break across lines
doi¦Typeset DOI links
cleveref¦Smart references with the type name
nameref¦Reference the name of a labelled item
natbib¦Author-year citations: \citep and \citet
biblatex¦Bibliographies with the biber backend
cite¦Compressed citation numbers
glossaries¦Glossaries, acronyms and symbol lists
glossaries-extra¦Extended glossaries for LuaLaTeX and XeLaTeX
acronym¦Acronym lists
nomencl¦Nomenclature lists
makeidx¦Index generation with makeindex
imakeidx¦Improved index generation
# ── Theorems and exercises ───────────────────────────────────────────────────
thmtools¦Declare theorem environments with options
ntheorem¦Alternative theorem environments
exsheets¦Exercise and problem sheets
# ── Tables ───────────────────────────────────────────────────────────────────
booktabs¦Professional table rules
array¦Extended column types and formats
tabularx¦Tables whose columns stretch to a width
tabulary¦Tables with flexible column widths
longtable¦Tables that span several pages
ltxtable¦Combine longtable and tabularx
supertabular¦Older multi-page tables
threeparttable¦Tables with notes below
multirow¦Multirow table cells
colortbl¦Coloured table cells and rows
makecell¦Multi-line cells in tables
diagbox¦Diagonal line in a table cell
dcolumn¦Decimal-aligned columns
# ── Floats, captions and pages ───────────────────────────────────────────────
float¦Improved float placement with the H option
placeins¦Keep floats from crossing sections
caption¦Customise captions
subcaption¦Subfigures and subtables with captions
subfig¦Subfigures, older interface
wrapfig¦Figures wrapped in text
rotating¦Rotated tables and figures
pdflscape¦Landscape pages with correct page numbers
lscape¦Landscape pages
adjustbox¦Adjust boxes and images: width, trim, frame
framed¦Framed and shaded boxes
mdframed¦Framed paragraphs that can break across pages
fancybox¦Boxes and frames with decorative shapes
tcolorbox¦Coloured and framed boxes with titles
# ── Graphics and drawing ─────────────────────────────────────────────────────
graphicx¦Include graphics and scale or rotate them
graphics¦Basic graphics support
pdfpages¦Include pages from other PDF files
epstopdf¦Convert EPS figures to PDF on the fly
svg¦Include SVG files (needs Inkscape)
standalone¦Compile figures as standalone documents
color¦Basic colour support
tikz¦Drawing and diagrams with TikZ
pgf¦Base layer of TikZ
pgffor¦Loops for TikZ with \foreach
pgfkeys¦Key-value interface for pgf
pgfplots¦Plots and data graphs
pgfplotstable¦Tables of data for pgfplots
tikz-cd¦Commutative diagrams with TikZ
tikz-feynman¦Feynman diagrams with TikZ
tkz-euclide¦Euclidean geometry drawings
circuitikz¦Electrical circuit diagrams
chemfig¦Chemical structure drawings
mhchem¦Chemical formulae and equations
forest¦Trees drawn with TikZ
qtree¦Linguistic trees
xy¦Commutative diagrams with Xy-pic
animate¦Animations in PDF
media9¦Embedded media and animations in PDF
multido¦Repeated commands with counters
subfiles¦Compile a part of a document on its own
import¦Input files from other directories
# ── Code and verbatim ────────────────────────────────────────────────────────
listings¦Typeset source code with highlighting
minted¦Highlighted code with Pygments (needs -shell-escape)
fancyvrb¦Verbatim text with options
verbatim¦Verbatim text and the comment environment
algorithm2e¦Algorithms with keywords and maths
algorithmicx¦Algorithmic pseudocode base
algpseudocode¦Pseudocode commands for algorithmicx
algorithm¦Floating algorithm environment
algorithmic¦Algorithmic environment
# ── Presentations and notes ──────────────────────────────────────────────────
beamer¦Slide presentations (document class)
pgfpages¦Several slides per page, and speaker notes
beamerposter¦Academic posters with beamer
# ── Miscellaneous ────────────────────────────────────────────────────────────
comment¦Comment out blocks of text
refcount¦Reference counting for macros
siunitx¦Units and numbers: \SI, \si, \num
csvsimple¦Tables from CSV files
libertine¦Linux Libertine text and math fonts
paralist¦Compact lists, older interface
epigraph¦Epigraphs at the start of chapters
authblk¦Author affiliations on the title page
icomma¦Decimal comma without extra spacing
wallpaper¦Background images on pages
tikz-3dplot¦Three-dimensional plots with TikZ
bytefield¦Byte and bit field diagrams
pgfgantt¦Gantt charts with TikZ
fixme¦Inline notes and to-do markers
academicons¦Academic icons such as ORCID and Google Scholar
marginnote¦Notes in the margin
draftcopy¦Draft watermark text
upquote¦Straight quotes in verbatim text
cmap¦Searchable and copyable text in PDF output
newunicodechar¦Map Unicode characters to LaTeX commands
kvsetkeys¦Key-value setting interface
numprint¦Number formatting
footnote¦Footnotes inside tables and minipages
cprotect¦Verbatim text inside macro arguments
"""#
}
