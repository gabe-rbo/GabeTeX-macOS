import SwiftUI

/// The presenter view: a calm dark room for the speaker.
///
/// ```
///  ELAPSED                        SLIDE                         TIME
///  12:34                          5 / 23                        14:05
///                          Slides on DELL U2720Q
///  CURRENT SLIDE                               NEXT SLIDE
///  ┌──────────────────────────────┐            ┌───────────────┐
///  │                              │            │               │
///  │                              │            └───────────────┘
///  │                              │            NOTES
///  │                              │            ┌───────────────┐
///  └──────────────────────────────┘            └───────────────┘
///        ( ‹ › )  ( ⏸ ↺ )  ( ◐ ○ )  ( Notes ▾  ⇄ )  [ End Presentation ]
/// ```
///
/// Slides sit on black; the controls are one Liquid Glass bar. Timer and clock use SF Mono digits. Nothing in it
/// takes the keyboard: every key goes to the presentation (see `PresentationWindow`).
struct PresenterView: View {
    let controller: PresentationController

    var body: some View {
        ZStack {
            PresenterBackdrop()
            VStack(spacing: 0) {
                PresenterHeader(controller: controller)
                    .padding(.horizontal, 44)
                    .padding(.top, 30)
                    .padding(.bottom, 22)
                PresenterSlides(controller: controller)
                    .padding(.horizontal, 44)
                PresenterControlBar(controller: controller)
                    .padding(.top, 22)
                    .padding(.bottom, 28)
            }
            if !controller.navigator.typedDigits.isEmpty {
                GoToSlideOverlay(controller: controller)
                    .transition(.opacity)
            }
        }
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Presenter View"))
    }
}

// MARK: - Backdrop

private struct PresenterBackdrop: View {
    var body: some View {
        LinearGradient(
            colors: [Color(red: 0.085, green: 0.09, blue: 0.105), Color(red: 0.035, green: 0.037, blue: 0.045)],
            startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

/// Small uppercase label above a readout or a panel.
private struct PresenterCaption: View {
    let text: Text

    init(_ key: LocalizedStringKey) {
        text = Text(key)
    }

    init(verbatim: String) {
        text = Text(verbatim: verbatim)
    }

    var body: some View {
        text
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.3)
            .textCase(.uppercase)
            .foregroundStyle(.white.opacity(0.46))
            .lineLimit(1)
    }
}

// MARK: - Header

private struct PresenterHeader: View {
    let controller: PresentationController

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            TimerReadout(controller: controller)
                .frame(maxWidth: .infinity, alignment: .leading)
            SlideCounter(controller: controller)
            ClockReadout()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

private struct TimerReadout: View {
    let controller: PresentationController

    var body: some View {
        let timer = controller.timer
        TimelineView(.periodic(from: Date(), by: 0.5)) { context in
            let elapsed = PresentationTimer.format(timer.elapsed(at: context.date))
            VStack(alignment: .leading, spacing: 6) {
                if timer.isRunning {
                    PresenterCaption("Elapsed")
                } else {
                    PresenterCaption("Paused")
                }
                Text(verbatim: elapsed)
                    .font(.system(size: 54, weight: .medium, design: .monospaced))
                    .foregroundStyle(timer.isRunning ? Color.white : Color.orange)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(timer.isRunning ? Text("Elapsed time") : Text("Timer paused"))
            .accessibilityValue(Text(verbatim: elapsed))
        }
    }
}

private struct SlideCounter: View {
    let controller: PresentationController

    var body: some View {
        let count = controller.pageCount
        let current = count > 0 ? controller.currentIndex + 1 : 0
        VStack(spacing: 6) {
            PresenterCaption("Slide")
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: "\(current)")
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(verbatim: "/ \(count)")
                    .font(.system(size: 24, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.5))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Slide \(current) of \(count)"))
            DeckProgress(fraction: count > 0 ? Double(current) / Double(count) : 0)
                .frame(width: 150, height: 3)
                .padding(.vertical, 2)
            displayStatus
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.42))
                .lineLimit(1)
        }
        .fixedSize()
    }

    @ViewBuilder private var displayStatus: some View {
        switch controller.layout {
        case .dual:
            if let name = controller.audienceDisplayName, !name.isEmpty {
                Text("Slides on \(name)")
            } else {
                Text("Slides on the other display")
            }
        case .single:
            Text("One display · P shows the slides")
        }
    }
}

/// A thin line showing how far into the deck the talk is.
private struct DeckProgress: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                Capsule()
                    .fill(.white.opacity(0.62))
                    .frame(width: proxy.size.width * min(max(fraction, 0), 1))
            }
        }
        .accessibilityHidden(true)
    }
}

private struct ClockReadout: View {
    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(alignment: .trailing, spacing: 6) {
                PresenterCaption("Time")
                Text(context.date, format: .dateTime.hour().minute())
                    .font(.system(size: 54, weight: .light, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - Slides

private struct PresenterSlides: View {
    let controller: PresentationController

    private static let captionHeight: CGFloat = 26
    private static let columnSpacing: CGFloat = 40
    private static let panelSpacing: CGFloat = 22

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let currentWidth = max(0, ((size.width - Self.columnSpacing) * 0.62).rounded(.down))
            let sideWidth = max(0, size.width - Self.columnSpacing - currentWidth)
            // Columns top-aligned with each other; the block centered in the space between header and controls.
            HStack(alignment: .top, spacing: Self.columnSpacing) {
                currentPanel(width: currentWidth, height: size.height)
                sidePanel(width: sideWidth, height: size.height)
            }
            .frame(width: size.width, height: size.height, alignment: .center)
        }
    }

    // MARK: Current

    private func currentPanel(width: CGFloat, height: CGFloat) -> some View {
        let deck = controller.deck
        let index = controller.currentIndex
        let box = CGSize(width: width, height: max(0, height - Self.captionHeight))
        let fitted = fit(deck.size(of: .slide, ofPage: index), in: box)
        let blank = controller.navigator.blank
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                PresenterCaption("Current Slide")
                if blank != .none {
                    BlankBadge(blank: blank)
                }
            }
            .frame(width: fitted.width, height: Self.captionHeight, alignment: .topLeading)
            SlideImage(deck: deck, renderer: controller.renderer, page: deck.pageCount > 0 ? index : nil,
                       part: .slide, prefetch: [1, -1], cornerRadius: 12,
                       accessibilityLabel: String(localized: "Current slide, \(index + 1) of \(deck.pageCount)"),
                       onClick: { [controller] in controller.perform(.next) })
                .frame(width: fitted.width, height: fitted.height)
                .overlay { BlankCover(blank: blank) }
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.1), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
        }
        .frame(width: width, alignment: .leading)
    }

    // MARK: Next + notes

    private func sidePanel(width: CGFloat, height: CGFloat) -> some View {
        let deck = controller.deck
        let index = controller.currentIndex
        let next = controller.nextIndex
        let hasNotes = deck.size(of: .notes, ofPage: index) != nil
        let slideSize = deck.size(of: .slide, ofPage: next ?? index)
        let usable = max(0, height - 2 * Self.captionHeight - Self.panelSpacing)
        // With notes, next slide and notes get the same box (same aspect: they are the two halves of a page), so the
        // two panels line up; without notes, the next slide may take a little more.
        let box = CGSize(width: width, height: hasNotes ? usable / 2 : usable * 0.55)
        let nextSize = fit(slideSize, in: box)
        let notesSize = fit(deck.size(of: .notes, ofPage: index), in: box)

        return VStack(alignment: .leading, spacing: 0) {
            PresenterCaption("Next Slide")
                .frame(height: Self.captionHeight, alignment: .topLeading)
            Group {
                if let next {
                    SlideImage(deck: deck, renderer: controller.renderer, page: next, part: .slide, prefetch: [1],
                               cornerRadius: 10,
                               accessibilityLabel: String(localized: "Next slide, \(next + 1) of \(deck.pageCount)"),
                               onClick: { [controller] in controller.perform(.next) })
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(.white.opacity(0.1), lineWidth: 1)
                                .allowsHitTesting(false)
                        }
                } else {
                    EndOfSlidesCard()
                }
            }
            .frame(width: nextSize.width, height: nextSize.height)

            Spacer().frame(height: Self.panelSpacing)

            PresenterCaption("Notes")
                .frame(height: Self.captionHeight, alignment: .topLeading)
            if hasNotes {
                SlideImage(deck: deck, renderer: controller.renderer, page: index, part: .notes, prefetch: [1],
                           cornerRadius: 10, accessibilityLabel: String(localized: "Notes for slide \(index + 1)"))
                    .frame(width: notesSize.width, height: notesSize.height)
            } else {
                NoNotesHint(mode: controller.notesMode)
                    .frame(maxWidth: width, alignment: .leading)
            }
        }
        .frame(width: width, alignment: .topLeading)
    }

    private func fit(_ size: CGSize?, in box: CGSize) -> CGSize {
        guard let size else {
            // No page yet: a 16:9 placeholder.
            return SlideGeometry.aspectFit(CGSize(width: 16, height: 9), in: CGRect(origin: .zero, size: box)).size
        }
        return SlideGeometry.aspectFit(size, in: CGRect(origin: .zero, size: box), scale: 2).size
    }
}

/// "Audience: black screen" beside the caption.
private struct BlankBadge: View {
    let blank: PresentationBlank

    var body: some View {
        Group {
            if blank == .white {
                Label("White Screen", systemImage: "sun.max.fill")
            } else {
                Label("Black Screen", systemImage: "eye.slash.fill")
            }
        }
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.orange.opacity(0.85)))
            .foregroundStyle(.black)
            .fixedSize()
    }
}

/// Dims the current slide while the audience sees a black or white screen.
private struct BlankCover: View {
    let blank: PresentationBlank

    var body: some View {
        if blank != .none {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.black.opacity(0.84))
                VStack(spacing: 10) {
                    Image(systemName: blank == .white ? "sun.max" : "eye.slash")
                        .font(.system(size: 34, weight: .regular))
                    if blank == .white {
                        Text("The audience sees a white screen")
                            .font(.title3.weight(.semibold))
                        Text("Press W or any arrow key to show the slides")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.65))
                    } else {
                        Text("The audience sees a black screen")
                            .font(.title3.weight(.semibold))
                        Text("Press B or any arrow key to show the slides")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(white: 0.12)))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.08)))
                .padding(24)
            }
            .allowsHitTesting(false)
        }
    }
}

private struct EndOfSlidesCard: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.white.opacity(0.05))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.white.opacity(0.1), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            }
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "flag.checkered")
                        .font(.system(size: 22))
                    Text("End of the presentation")
                        .font(.callout.weight(.medium))
                }
                .foregroundStyle(.white.opacity(0.5))
            }
    }
}

/// Shown in place of the notes when the pages have none.
private struct NoNotesHint: View {
    let mode: PresentationNotesMode

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No notes for these slides")
                .font(.callout.weight(.medium))
                .foregroundStyle(.white.opacity(0.55))
            if mode != .off {
                Text("To see Beamer notes here, add \\setbeameroption{show notes on second screen} to the preamble and write \\note{…} in your frames.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.38))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 2)
    }
}

// MARK: - Go to slide

private struct GoToSlideOverlay: View {
    let controller: PresentationController

    var body: some View {
        let navigator = controller.navigator
        let deck = controller.deck
        let target = navigator.typedTargetIndex
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            VStack(spacing: 16) {
                PresenterCaption("Go to Slide")
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(verbatim: navigator.typedDigits)
                        .font(.system(size: 64, weight: .semibold, design: .monospaced))
                    Text(verbatim: "/ \(deck.pageCount)")
                        .font(.system(size: 26, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                }
                if let target {
                    let size = SlideGeometry.aspectFit(deck.size(of: .slide, ofPage: target) ?? CGSize(width: 16, height: 9),
                                                       in: CGRect(x: 0, y: 0, width: 320, height: 200), scale: 2).size
                    SlideImage(deck: deck, renderer: controller.renderer, page: target, part: .slide, cornerRadius: 8,
                               accessibilityLabel: String(localized: "Slide \(target + 1) of \(deck.pageCount)"))
                        .frame(width: size.width, height: size.height)
                }
                Text("Return to go · Esc to cancel")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
            .glassEffect(.regular.tint(.black.opacity(0.35)), in: .rect(cornerRadius: 30))
        }
    }
}
