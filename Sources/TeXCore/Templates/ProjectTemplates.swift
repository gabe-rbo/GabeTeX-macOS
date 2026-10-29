import Foundation

/// Built-in "New Project…" templates. File contents use `{{TITLE}}`, `{{AUTHOR}}` and `{{DATE}}`,
/// filled in by `ProjectTemplate.instantiate(title:author:date:)`. Every template compiles with pdflatex
/// (biblatex templates also need biber, which MacTeX ships).
public enum ProjectTemplates {
    public static let all: [ProjectTemplate] = [
        ProjectTemplate(
            id: "article",
            name: String(localized: "Article"),
            summary: String(localized: "A simple article in a single file."),
            symbolName: "doc.text",
            files: [
                "main.tex": articleMain,
            ]
        ),
        ProjectTemplate(
            id: "article-sections",
            name: String(localized: "Article with Sections"),
            summary: String(localized: "A main file that inputs one file per section, plus a bibliography."),
            symbolName: "list.bullet.indent",
            files: [
                "main.tex": sectionsMain,
                "sections/introduction.tex": sectionsIntroduction,
                "sections/preliminaries.tex": sectionsPreliminaries,
                "sections/main-results.tex": sectionsMainResults,
                "sections/conclusion.tex": sectionsConclusion,
                "references.bib": exampleBib,
            ]
        ),
        ProjectTemplate(
            id: "thesis",
            name: String(localized: "Thesis"),
            summary: String(localized: "A book-class thesis with front matter, chapters and biblatex."),
            symbolName: "book.closed",
            files: [
                "main.tex": thesisMain,
                "chapters/introduction.tex": thesisIntroduction,
                "chapters/background.tex": thesisBackground,
                "chapters/conclusion.tex": thesisConclusion,
                "references.bib": exampleBib,
                "figures/README.txt": thesisFiguresReadme,
            ]
        ),
        ProjectTemplate(
            id: "beamer",
            name: String(localized: "Beamer Presentation"),
            summary: String(localized: "Slides with a title page, blocks and columns."),
            symbolName: "play.rectangle",
            files: [
                "main.tex": beamerMain,
            ]
        ),
        ProjectTemplate(
            id: "math-notes",
            name: String(localized: "Math Notes"),
            summary: String(localized: "Theorem environments, macros, a commutative diagram and hyperlinks."),
            symbolName: "function",
            files: [
                "main.tex": mathNotesMain,
                "macros.tex": mathNotesMacros,
            ]
        ),
        ProjectTemplate(
            id: "problem-set",
            name: String(localized: "Problem Set"),
            summary: String(localized: "Numbered problems and solutions with a running header."),
            symbolName: "checklist",
            files: [
                "main.tex": problemSetMain,
            ]
        ),
    ]
}

// MARK: - Template sources
//
// Kept at column 0 so that the file contents are exactly the text between the delimiters.

extension ProjectTemplates {
    // article
    private static let articleMain = #"""
\documentclass[11pt]{article}

% \usepackage[brazilian]{babel}
\usepackage[T1]{fontenc}
\usepackage{lmodern}
\usepackage{amsmath,amssymb}
\usepackage{hyperref}

\title{{{TITLE}}}
\author{{{AUTHOR}}}
\date{{{DATE}}}

\begin{document}
\maketitle

\begin{abstract}
A short summary of the article goes here.
\end{abstract}

\section{Introduction}
Hello, world! Inline mathematics such as $e^{i\pi} + 1 = 0$ works out of the box.

\begin{equation}
  \int_0^1 x^2\,dx = \frac{1}{3}.
\end{equation}

\end{document}
"""#

    // article-sections
    private static let sectionsMain = #"""
\documentclass[11pt]{article}

% \usepackage[brazilian]{babel}
\usepackage[T1]{fontenc}
\usepackage{lmodern}
\usepackage{amsmath,amssymb,amsthm}
\usepackage{natbib}
\usepackage[colorlinks=true,linkcolor=blue,citecolor=blue,urlcolor=blue]{hyperref}
\usepackage{cleveref}

\theoremstyle{plain}
\newtheorem{theorem}{Theorem}[section]
\newtheorem{lemma}[theorem]{Lemma}
\newtheorem{proposition}[theorem]{Proposition}
\newtheorem{corollary}[theorem]{Corollary}
\theoremstyle{definition}
\newtheorem{definition}[theorem]{Definition}
\theoremstyle{remark}
\newtheorem{remark}[theorem]{Remark}

\title{{{TITLE}}}
\author{{{AUTHOR}}}
\date{{{DATE}}}

\begin{document}
\maketitle

\begin{abstract}
A short summary of the article goes here.
\end{abstract}

\input{sections/introduction}
\input{sections/preliminaries}
\input{sections/main-results}
\input{sections/conclusion}

\bibliographystyle{plainnat}
\bibliography{references}

\end{document}
"""#

    private static let sectionsIntroduction = #"""
% !TEX root = ../main.tex

\section{Introduction}\label{sec:introduction}

Write the introduction here. The results are stated in \cref{sec:main-results}, which builds on the definitions of \cref{sec:preliminaries}. Citations look like \citet{example} or \citep{example}.
"""#

    private static let sectionsPreliminaries = #"""
% !TEX root = ../main.tex

\section{Preliminaries}\label{sec:preliminaries}

\begin{definition}\label{def:example}
Let $X$ be a set. A \emph{partition} of $X$ is a family of nonempty, pairwise disjoint subsets of $X$ whose union is $X$.
\end{definition}

\begin{remark}
Replace this with your own notation and definitions.
\end{remark}
"""#

    private static let sectionsMainResults = #"""
% !TEX root = ../main.tex

\section{Main results}\label{sec:main-results}

\begin{theorem}\label{thm:main}
Let $X$ be a set with a partition $\mathcal{P}$. Then the relation $x \sim y$, defined by ``$x$ and $y$ lie in a common part of $\mathcal{P}$'', is an equivalence relation on $X$, and its classes are exactly the parts of $\mathcal{P}$.
\end{theorem}

\begin{proof}
Every $x \in X$ lies in exactly one part of $\mathcal{P}$, which gives reflexivity; symmetry and transitivity are immediate from the definition. Since the parts are disjoint and cover $X$, the classes are exactly the parts.
\end{proof}

By \cref{def:example} and \cref{thm:main}, every partition determines an equivalence relation.
"""#

    private static let sectionsConclusion = #"""
% !TEX root = ../main.tex

\section{Conclusion}\label{sec:conclusion}

Summarise the contributions of \cref{thm:main}, then discuss open questions. Background material can be cited with \citep{example}.
"""#

    // thesis
    private static let thesisMain = #"""
\documentclass[12pt,a4paper,oneside]{book}

\usepackage[T1]{fontenc}
\usepackage{lmodern}
\usepackage[a4paper,margin=2.5cm]{geometry}
\usepackage{amsmath,amssymb,amsthm}
\usepackage{graphicx}
\usepackage[backend=biber,style=numeric,sorting=nyt]{biblatex}
\addbibresource{references.bib}
\usepackage[colorlinks=true,linkcolor=black,citecolor=black,urlcolor=blue]{hyperref}
\usepackage{cleveref}
% \usepackage[brazilian]{babel}

\title{{{TITLE}}}
\author{{{AUTHOR}}}
\date{{{DATE}}}

\begin{document}

\frontmatter
\maketitle

\chapter*{Abstract}
Write the abstract of your thesis here.

\tableofcontents

\mainmatter
\include{chapters/introduction}
\include{chapters/background}
\include{chapters/conclusion}

\backmatter
\printbibliography[heading=bibintoc]

\end{document}
"""#

    private static let thesisIntroduction = #"""
% !TEX root = ../main.tex

\chapter{Introduction}\label{chap:introduction}

Write the introduction here. The background material is in \cref{chap:background}.
"""#

    private static let thesisBackground = #"""
% !TEX root = ../main.tex

\chapter{Background}\label{chap:background}

\section{Notation}\label{sec:notation}

Describe your notation here. Standard facts can be cited, for example \parencite{example}.
"""#

    private static let thesisConclusion = #"""
% !TEX root = ../main.tex

\chapter{Conclusion}\label{chap:conclusion}

Summarise your results here.
"""#

    private static let thesisFiguresReadme = #"""
Put the figure files of this thesis in this folder, for example figures/plot.pdf, and include them with
\includegraphics[width=0.8\linewidth]{figures/plot}
"""#

    // shared bibliography for the article and thesis templates
    private static let exampleBib = #"""
@book{example,
  author    = {Author, Example},
  title     = {An Example Reference},
  publisher = {Example Publisher},
  year      = {2026}
}
"""#

    // beamer
    private static let beamerMain = #"""
\documentclass[aspectratio=169]{beamer}

\usetheme{Madrid}
\usepackage[T1]{fontenc}
\usepackage{lmodern}
\usepackage{amsmath,amssymb}
% \usepackage[brazilian]{babel}

\title{{{TITLE}}}
\author{{{AUTHOR}}}
\date{{{DATE}}}

\begin{document}

\begin{frame}
  \titlepage
\end{frame}

\begin{frame}{Outline}
  \tableofcontents
\end{frame}

\section{Motivation}

\begin{frame}{Motivation}
  \begin{itemize}
    \item<1-> The first point, shown immediately.
    \item<2-> The second point, shown after a click.
  \end{itemize}

  \begin{block}{Key idea}
    A short statement of the main idea goes in this block.
  \end{block}
\end{frame}

\section{Results}

\begin{frame}{Two columns}
  \begin{columns}[T]
    \begin{column}{0.48\textwidth}
      Text on the left, with inline mathematics $x^2 + y^2 = r^2$.
    \end{column}
    \begin{column}{0.48\textwidth}
      \begin{alertblock}{Caution}
        Text on the right, highlighted as an alert.
      \end{alertblock}
    \end{column}
  \end{columns}
\end{frame}

\begin{frame}{Overlays}
  Content that appears in steps:
  \begin{enumerate}
    \item<1-> First step.
    \item<2-> Second step.
  \end{enumerate}
  \pause
  \alert{This line appears after a pause.}
\end{frame}

\begin{frame}
  \centering
  \Huge Thank you!
\end{frame}

\end{document}
"""#

    // math-notes
    private static let mathNotesMain = #"""
\documentclass[11pt]{amsart}

\usepackage[T1]{fontenc}
\usepackage{lmodern}
\usepackage{amssymb,mathtools}
\usepackage{tikz-cd}
\usepackage[colorlinks=true,linkcolor=blue,citecolor=blue,urlcolor=blue]{hyperref}
\usepackage[capitalise,nameinlink]{cleveref}
% \usepackage[brazilian]{babel}

\input{macros}

\theoremstyle{plain}
\newtheorem{theorem}{Theorem}[section]
\newtheorem{lemma}[theorem]{Lemma}
\newtheorem{proposition}[theorem]{Proposition}
\newtheorem{corollary}[theorem]{Corollary}
\theoremstyle{definition}
\newtheorem{definition}[theorem]{Definition}
\newtheorem{example}[theorem]{Example}
\theoremstyle{remark}
\newtheorem{remark}[theorem]{Remark}

\title{{{TITLE}}}
\author{{{AUTHOR}}}
\date{{{DATE}}}

\begin{document}
\maketitle

\begin{abstract}
A short summary of these notes.
\end{abstract}

\section{Setting}

Let $\Z$ denote the integers and $\R$ the real numbers.

\begin{definition}\label{def:injective}
A map $f\colon X \to Y$ is \emph{injective} if $f(x) = f(x')$ implies $x = x'$.
\end{definition}

\section{A sample result}

\begin{theorem}[Sample]\label{thm:sample}
Let $f\colon X \to Y$ be a map of sets. If $f$ has a left inverse, then $f$ is injective.
\end{theorem}

\begin{proof}
Let $g\colon Y \to X$ satisfy $g \circ f = \id_X$. If $f(x) = f(x')$, then
\[
  x = g\bigl(f(x)\bigr) = g\bigl(f(x')\bigr) = x'.
\]
\end{proof}

\begin{example}
The inclusion $\N \hookrightarrow \Z$ is injective.
\end{example}

\section{A commutative diagram}

Consider the square of maps below.

\[
\begin{tikzcd}
  A \arrow[r, "f"] \arrow[d, "g"'] & B \arrow[d, "h"] \\
  C \arrow[r, "k"'] & D
\end{tikzcd}
\]

\end{document}
"""#

    private static let mathNotesMacros = #"""
% Number sets
\newcommand{\N}{\mathbb{N}}
\newcommand{\Z}{\mathbb{Z}}
\newcommand{\Q}{\mathbb{Q}}
\newcommand{\R}{\mathbb{R}}
\newcommand{\C}{\mathbb{C}}

% Operators, set upright with the right spacing
\DeclareMathOperator{\Hom}{Hom}
\DeclareMathOperator{\id}{id}
\DeclareMathOperator{\im}{im}

% Paired delimiters that resize with \left and \right
\DeclarePairedDelimiter{\abs}{\lvert}{\rvert}
\DeclarePairedDelimiter{\norm}{\lVert}{\rVert}
\DeclarePairedDelimiter{\set}{\{}{\}}

% Categories
\newcommand{\cat}[1]{\mathsf{#1}}
"""#

    // problem-set
    private static let problemSetMain = #"""
\documentclass[11pt]{article}

\usepackage[T1]{fontenc}
\usepackage{lmodern}
\usepackage[margin=2.5cm]{geometry}
\usepackage{amsmath,amssymb,amsthm}
\usepackage{fancyhdr}
\usepackage[colorlinks=true,linkcolor=blue]{hyperref}
% \usepackage[brazilian]{babel}

\newcounter{problem}
\newenvironment{problem}
  {\refstepcounter{problem}\par\medskip\noindent\textbf{Problem \theproblem.}\quad\ignorespaces}
  {\par\medskip}
\newenvironment{solution}
  {\par\medskip\noindent\emph{Solution.}\quad\ignorespaces}
  {\hfill$\square$\par\medskip}

\pagestyle{fancy}
\fancyhf{}
\lhead{{{TITLE}}}
\rhead{{{AUTHOR}}}
\rfoot{\thepage}

\title{{{TITLE}}}
\author{{{AUTHOR}}}
\date{{{DATE}}}

\begin{document}
\maketitle

\begin{problem}\label{prob:cyclic}
Show that every group of prime order is cyclic.
\end{problem}

\begin{solution}
Let $G$ have prime order $p$ and pick $g \in G$ with $g \neq e$. The order of $g$ divides $p$ and is not $1$, so it equals $p$. Hence $\langle g \rangle = G$.
\end{solution}

\begin{problem}\label{prob:sum}
Compute $\sum_{k=1}^{n} k$ for every integer $n \geq 1$.
\end{problem}

\begin{solution}
The formula is $\sum_{k=1}^{n} k = \dfrac{n(n+1)}{2}$. It holds for $n = 1$, and if it holds for $n$, then adding $n+1$ gives $\dfrac{n(n+1)}{2} + (n+1) = \dfrac{(n+1)(n+2)}{2}$, so it holds for $n+1$ as well. Induction finishes the proof.
\end{solution}

\end{document}
"""#
}
