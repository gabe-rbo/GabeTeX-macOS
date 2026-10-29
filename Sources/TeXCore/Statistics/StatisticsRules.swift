import Foundation

/// The tables behind the counting rules: which commands swallow their arguments, which environments are
/// skipped, which ones take non-text arguments. See `DocumentStatistics` for the rules in prose.
enum StatisticsRules {
    enum Action {
        /// An ordinary command: it ends the word before it, an attached `[option]` or `<overlay>` is dropped
        /// and its `{arguments}` are read as text (`\emph{x}`, `\textbf{x}`, `\footnote{x}`, `\caption{x}` …).
        case unknown
        /// Ends the word and nothing else (`\item`, whose `[label]` is text).
        case separator
        /// `\section` & co: the title counts as heading words.
        case heading
        /// `\frametitle`, `\framesubtitle`.
        case frameTitle
        case begin
        case end
        /// `\input`, `\include`, `\subfile`, `\import`, `\subimport`: the file is walked at this point.
        case include
        /// The first `n` mandatory arguments (with their `[options]`) are not text.
        case ignoreArguments(Int)
        /// `\newcommand`-like: the name, the options and `bodies` brace groups are code, not text.
        case definition(bodies: Int)
        /// `\def\foo#1{…}`.
        case plainDefinition
        /// `\newtheorem{name}[counter]{Title}[within]`: remembers `name` as an environment with a titled `[option]`.
        case newTheorem
        /// `\declaretheorem[options]{names}`.
        case declareTheorem
        /// `\ss \ae \o \i …`: a letter that continues the word.
        case letter
        /// `\c \v \u \H \k \r \b \d \t`: an accent over the next letter, which continues the word.
        case accent
        /// `\texorpdfstring{TeX}{pdf}`: only the first argument counts.
        case texorpdfstring
        /// `\cmidrule(lr){2-3}`.
        case cmidrule
        /// `\caption`, `\captionof{type}`, `\subcaption`: the text counts even inside a figure or a table.
        /// `typeArguments` mandatory arguments come before the `[short title]` and the `{text}`.
        case caption(typeArguments: Int)
        /// `\subfloat[caption]{content}`, `\subfigure[caption]{content}`: the last `[option]` is the caption.
        case subCaption
    }

    static func action(for name: String) -> Action {
        if let known = commands[name] { return known }
        if LaTeXSyntax.isCiteLike(name) { return .ignoreArguments(1) }
        return .unknown
    }

    static let commands: [String: Action] = {
        var table: [String: Action] = [:]
        for name in LaTeXSyntax.sectioningKinds.keys { table[name] = .heading }
        table["title"] = .heading
        table["frametitle"] = .frameTitle
        table["framesubtitle"] = .frameTitle
        table["begin"] = .begin
        table["end"] = .end
        for name in ["input", "include", "subfile", "import", "subimport"] { table[name] = .include }
        table["item"] = .separator

        // Commands whose first argument(s) are names, keys, lengths or files — never text.
        let oneArgument = [
            "label", "ref", "eqref", "pageref", "autoref", "Autoref", "nameref", "vref", "Vref", "cref", "Cref",
            "labelcref", "cpageref", "Cpageref", "subref", "nocite", "bibliography", "bibliographystyle",
            "addbibresource", "addglobalbib", "addsectionbib", "includegraphics", "includepdf", "includesvg",
            "includestandalone", "graphicspath", "usepackage", "RequirePackage", "RequirePackageWithOptions",
            "LoadClass", "documentclass", "usetikzlibrary", "usepgflibrary", "usepgfplotslibrary", "lstinputlisting",
            "pagestyle", "thispagestyle", "pagenumbering", "stepcounter", "refstepcounter", "newcounter",
            "newlength", "hypersetup", "geometry", "newgeometry", "vspace", "hspace", "vphantom", "hphantom",
            "phantom", "color", "pagecolor", "selectlanguage", "babelprovide", "index", "glossary", "hyphenation",
            "enlargethispage", "markright", "captionsetup", "lstset", "tikzset", "pgfplotsset", "includeonly",
            "bibitem", "url", "nolinkurl", "href", "hypertarget", "hyperlink", "textcolor", "colorbox",
            "cellcolor", "rowcolor", "columncolor", "arrayrulecolor", "cline", "foreignlanguage",
            "scalebox", "rotatebox", "usetheme", "usecolortheme", "usefonttheme", "useoutertheme",
            "useinnertheme", "setbeameroption", "theoremstyle", "fancyhead", "fancyfoot", "fancyhf", "lhead",
            "chead", "rhead", "lfoot", "cfoot", "rfoot", "setmainfont", "setsansfont", "setmonofont",
            "setmathfont", "setdefaultlanguage", "setotherlanguage", "bookmark",
            // The title block is not prose (texcount ignores `\author` and `\date` too); `\title` is a heading.
            "author", "date", "parbox", "raisebox", "special", "typeout", "typein", "newsavebox", "usebox",
            "usecounter", "fontfamily", "fontseries", "addvspace", "eqlabel", "alph", "arabic", "fnsymbol",
            "roman", "value", "mint",
        ]
        for name in oneArgument { table[name] = .ignoreArguments(1) }
        let twoArguments = [
            "setcounter", "addtocounter", "setlength", "addtolength", "settowidth", "settoheight", "colorlet",
            "markboth", "pdfbookmark", "addtocontents", "setkeys", "rule", "resizebox", "multicolumn", "newfont",
            "fontsize", "sbox", "savebox", "settodepth", "mintinline",
            "multirow", "crefrange", "Crefrange", "cpagerefrange", "inputminted", "fcolorbox", "setbeamercolor",
            "setbeamerfont", "setbeamertemplate", "numberwithin", "newfontfamily",
        ]
        for name in twoArguments { table[name] = .ignoreArguments(2) }
        for name in ["definecolor", "addcontentsline"] { table[name] = .ignoreArguments(3) }
        // `\printbibliography[heading=…]` only has options: they are dropped as attached options too.
        table["printbibliography"] = .ignoreArguments(0)

        for name in ["newcommand", "renewcommand", "providecommand", "DeclareRobustCommand", "newrobustcmd",
                     "renewrobustcmd", "providerobustcmd", "DeclareMathOperator", "NewEnviron", "RenewEnviron",
                     "newtcolorbox", "renewtcolorbox", "newmdtheoremenv"] {
            table[name] = .definition(bodies: 1)
        }
        for name in ["newenvironment", "renewenvironment", "NewDocumentCommand", "RenewDocumentCommand",
                     "ProvideDocumentCommand", "DeclareDocumentCommand", "NewExpandableDocumentCommand",
                     "RenewExpandableDocumentCommand", "ProvideExpandableDocumentCommand",
                     "DeclareExpandableDocumentCommand", "DeclarePairedDelimiter", "NewTColorBox",
                     "DeclareTColorBox"] {
            table[name] = .definition(bodies: 2)
        }
        for name in ["NewDocumentEnvironment", "RenewDocumentEnvironment", "ProvideDocumentEnvironment",
                     "DeclareDocumentEnvironment", "DeclarePairedDelimiterX", "newtcbtheorem"] {
            table[name] = .definition(bodies: 3)
        }
        for name in ["def", "gdef", "edef", "xdef"] { table[name] = .plainDefinition }
        table["newtheorem"] = .newTheorem
        table["declaretheorem"] = .declareTheorem

        for name in ["ss", "ae", "AE", "oe", "OE", "aa", "AA", "o", "O", "l", "L", "i", "j", "dh", "DH",
                     "th", "TH", "ng", "NG", "dj", "DJ",
                     // Logos that print as one word (texcount counts `\LaTeX` and `\TeX` too).
                     "LaTeX", "LaTeXe", "TeX", "BibTeX", "XeTeX", "LuaTeX", "XeLaTeX", "LuaLaTeX"] {
            table[name] = .letter
        }
        for name in ["c", "v", "u", "H", "k", "r", "b", "d", "t"] { table[name] = .accent }
        table["texorpdfstring"] = .texorpdfstring
        table["cmidrule"] = .cmidrule
        table["caption"] = .caption(typeArguments: 0)
        table["subcaption"] = .caption(typeArguments: 0)
        table["captionof"] = .caption(typeArguments: 1)
        for name in ["subfloat", "subfigure", "subtable"] { table[name] = .subCaption }
        return table
    }()

    // MARK: Environments

    /// Environments whose whole body is code, data or layout, not prose: pictures, the bibliography, tables
    /// (`tabular` & co.), `tabbing`, `titlepage` and `lrbox` (the last four are `texcount`'s ignored
    /// environments too).
    static let skippedEnvironments: Set<String> = [
        "tikzpicture", "pgfpicture", "picture", "pspicture", "tikzcd", "circuitikz", "forest", "axis",
        "semilogxaxis", "semilogyaxis", "loglogaxis", "pgfonlayer", "scope", "thebibliography", "asy",
        "chessboard", "tikzpicture*",
        "tabular", "tabular*", "tabularx", "tabulary", "tabu", "longtabu", "tblr", "NiceTabular", "NiceTabular*",
        "supertabular", "xtabular", "mpsupertabular", "tabbing", "titlepage", "lrbox",
    ]

    /// Floats: the body is not prose (figures, nested boxes, text in a `minipage` next to a picture …) but the
    /// captions inside count. Like `texcount`'s `figure`/`table` rule, extended to the usual variants.
    static let floatEnvironments: Set<String> = [
        "figure", "figure*", "table", "table*", "float", "wrapfigure", "wraptable", "sidewaysfigure",
        "sidewaysfigure*", "sidewaystable", "sidewaystable*", "subfigure", "subtable", "longtable", "longtable*",
        "SCfigure", "SCtable", "marginfigure", "margintable",
    ]

    /// Mandatory arguments right after `\begin{name}` that are specifications, not text.
    static let environmentArguments: [String: Int] = [
        "longtable": 1, "array": 1,
        "minipage": 1, "multicols": 1, "multicols*": 1, "wrapfigure": 2, "wraptable": 2, "subfigure": 1,
        "subtable": 1, "adjustbox": 1, "column": 1, "spacing": 1, "otherlanguage": 1, "otherlanguage*": 1,
        "adjustwidth": 2, "list": 2, "algorithmic": 0, "minted": 1,
    ]

    /// Environments whose specification argument is followed by an `[option]` that is text, not settings:
    /// `\begin{multicols}{2}[Title]`.
    static let environmentsWithTitleOption: Set<String> = ["multicols", "multicols*"]

    /// Environments whose `[option]` is a title that reads as text (`\begin{theorem}[Pythagoras]`). The set
    /// grows with every `\newtheorem` / `\declaretheorem` seen.
    static let defaultTitledEnvironments: Set<String> = [
        "theorem", "lemma", "proposition", "corollary", "definition", "remark", "example", "proof", "conjecture",
        "claim", "fact", "exercise", "problem", "solution", "note", "axiom", "observation", "question",
        "notation", "assumption", "hypothesis", "principle",
    ]
}
