import AppKit
import CheckKit
import PreviewKit

// Headless checks of presentation mode (owned by the present agent). This file: the pure logic — navigation state
// machine, slide-number entry, blank screens, clamping on reload, keyboard model, timer, Beamer notes split, aspect
// fitting, display planning and the preamble scan. `PresentationRenderingChecks.swift`: PDF transitions, rendering,
// the controller, and the windows / presenter view / Touch Bar built offscreen. No window is ever ordered on screen.

func presentationChecks() async {
    await navigationChecks()
    await keyboardAndTimerChecks()
    await geometryChecks()
    await sourceChecks()
    await presentationRenderingChecks()
}

private func keyPress(_ code: UInt16, _ characters: String = "", shift: Bool = false, option: Bool = false,
                      command: Bool = false, control: Bool = false) -> PresentationCommand? {
    PresentationKeyMap.command(for: PresentationKeyPress(keyCode: code, characters: characters, shift: shift,
                                                         option: option, command: command, control: control))
}

private func navigationChecks() async {
    await Check.suite("Presentation: navigation state machine") {
        var nav = PresentationNavigator(pageCount: 5)
        Check.equal(nav.currentIndex, 0)
        Check.equal(nav.previousIndex, nil)
        Check.equal(nav.perform(.previous), .none, "no slide before the first")
        Check.equal(nav.perform(.next), .moved(from: 0, to: 1))
        Check.equal(nav.nextIndex, 2)
        Check.equal(nav.perform(.last), .moved(from: 1, to: 4))
        Check.expect(nav.isOnLastSlide)
        Check.equal(nav.nextIndex, nil)
        Check.equal(nav.perform(.next), .none, "the last slide stays (the presentation never ends by itself)")
        Check.equal(nav.perform(.first), .moved(from: 4, to: 0))
        Check.equal(nav.perform(.confirm), .moved(from: 0, to: 1), "Return without digits = next")
        Check.equal(nav.perform(.deleteBackward), .moved(from: 1, to: 0), "Delete without digits = previous")
        Check.equal(nav.perform(.goTo(3)), .moved(from: 0, to: 3))
        Check.equal(nav.perform(.goTo(99)), .moved(from: 3, to: 4), "goTo clamps")
        Check.equal(nav.perform(.goTo(-2)), .moved(from: 4, to: 0))
        Check.equal(nav.perform(.goTo(0)), .none)
        Check.equal(nav.perform(.togglePresenterView), .togglePresenterView)
        Check.equal(nav.perform(.escape), .end, "Esc without digits ends")
        Check.equal(nav.perform(.end), .end)

        Check.equal(PresentationNavigator(pageCount: 5, startIndex: 10).currentIndex, 4, "start index clamped")
        Check.equal(PresentationNavigator(pageCount: 5, startIndex: -3).currentIndex, 0)
        var empty = PresentationNavigator(pageCount: 0)
        Check.equal(empty.perform(.next), .none)
        Check.equal(empty.perform(.last), .none)
        Check.equal(empty.perform(.digit(3)), .none, "no digits without pages")
        Check.equal(empty.currentIndex, 0)
        Check.expect(empty.isOnLastSlide)
        Check.equal(PresentationNavigator(pageCount: -4).pageCount, 0)
    }

    await Check.suite("Presentation: slide number entry") {
        var nav = PresentationNavigator(pageCount: 23, startIndex: 4)
        Check.equal(nav.perform(.digit(1)), .digitsChanged)
        Check.equal(nav.typedDigits, "1")
        Check.equal(nav.typedTargetIndex, 0)
        Check.equal(nav.perform(.digit(2)), .digitsChanged)
        Check.equal(nav.typedSlideNumber, 12)
        Check.equal(nav.typedTargetIndex, 11)
        Check.equal(nav.perform(.deleteBackward), .digitsChanged, "Delete removes a digit")
        Check.equal(nav.typedDigits, "1")
        Check.equal(nav.currentIndex, 4)
        _ = nav.perform(.digit(7))
        Check.equal(nav.perform(.confirm), .moved(from: 4, to: 16), "1, 7, Return → slide 17")
        Check.equal(nav.typedDigits, "")

        _ = nav.perform(.digit(9))
        _ = nav.perform(.digit(9))
        Check.equal(nav.typedTargetIndex, 22, "99 clamps to the last slide")
        Check.equal(nav.perform(.confirm), .moved(from: 16, to: 22))
        _ = nav.perform(.digit(0))
        Check.equal(nav.perform(.confirm), .moved(from: 22, to: 0), "0 goes to the first slide")

        _ = nav.perform(.digit(5))
        Check.equal(nav.perform(.escape), .digitsChanged, "Esc cancels the entry, it does not end")
        Check.equal(nav.typedDigits, "")
        Check.equal(nav.currentIndex, 0)

        for digit in [1, 2, 3, 4, 5] { _ = nav.perform(.digit(digit)) }
        Check.equal(nav.typedDigits, "12345")
        Check.equal(nav.perform(.digit(6)), .none, "at most \(PresentationNavigator.maximumDigits) digits")
        Check.equal(nav.perform(.clearDigits), .digitsChanged)
        Check.equal(nav.perform(.clearDigits), .none)
        Check.equal(nav.perform(.digit(10)), .none, "not a digit")

        _ = nav.perform(.digit(3))
        Check.equal(nav.perform(.next), .moved(from: 0, to: 1), "navigation drops the entry and moves")
        Check.equal(nav.typedDigits, "")
        _ = nav.perform(.digit(2))
        Check.equal(nav.perform(.confirm), .digitsChanged, "typing the current slide only clears the entry")
        _ = nav.perform(.digit(2))
        Check.equal(nav.perform(.end), .end)
        Check.equal(nav.typedDigits, "")
    }

    await Check.suite("Presentation: black and white screens") {
        var nav = PresentationNavigator(pageCount: 5, startIndex: 2)
        Check.equal(nav.perform(.toggleBlack), .blankChanged(.black))
        Check.equal(nav.blank, .black)
        Check.equal(nav.perform(.next), .blankChanged(.none), "a navigation key only brings the slides back")
        Check.equal(nav.currentIndex, 2)
        Check.equal(nav.perform(.toggleWhite), .blankChanged(.white))
        Check.equal(nav.perform(.toggleBlack), .blankChanged(.black), "white → black directly")
        Check.equal(nav.perform(.toggleBlack), .blankChanged(.none), "B again shows the slides")
        _ = nav.perform(.toggleBlack)
        Check.equal(nav.perform(.previous), .blankChanged(.none))
        Check.equal(nav.currentIndex, 2)
        _ = nav.perform(.toggleWhite)
        Check.equal(nav.perform(.goTo(4)), .moved(from: 2, to: 4), "a jump shows the slides and moves")
        Check.equal(nav.blank, .none)
        _ = nav.perform(.toggleBlack)
        _ = nav.perform(.digit(1))
        Check.equal(nav.perform(.confirm), .moved(from: 4, to: 0))
        Check.equal(nav.blank, .none)
        _ = nav.perform(.toggleBlack)
        _ = nav.perform(.digit(1))
        Check.equal(nav.perform(.confirm), .blankChanged(.none), "jump to the same slide shows it")
        _ = nav.perform(.digit(4))
        Check.equal(nav.perform(.toggleWhite), .blankChanged(.white))
        Check.equal(nav.typedDigits, "", "blanking drops the entry")
    }

    await Check.suite("Presentation: clamping on reload") {
        var nav = PresentationNavigator(pageCount: 10, startIndex: 7)
        nav.updatePageCount(12)
        Check.equal(nav.currentIndex, 7, "more pages: same slide")
        nav.updatePageCount(5)
        Check.equal(nav.currentIndex, 4, "fewer pages: clamped to the last")
        Check.equal(nav.pageCount, 5)
        _ = nav.perform(.digit(3))
        nav.updatePageCount(0)
        Check.equal(nav.currentIndex, 0)
        Check.equal(nav.typedDigits, "")
        nav.updatePageCount(3)
        Check.equal(nav.currentIndex, 0)
        Check.equal(nav.perform(.next), .moved(from: 0, to: 1))
    }
}

private func keyboardAndTimerChecks() async {
    typealias Code = PresentationKeyMap.KeyCode

    await Check.suite("Presentation: keyboard model") {
        Check.equal(keyPress(Code.rightArrow), .next)
        Check.equal(keyPress(Code.downArrow), .next)
        Check.equal(keyPress(Code.space, " "), .next)
        Check.equal(keyPress(Code.space, " ", shift: true), .previous)
        Check.equal(keyPress(Code.pageDown), .next)
        Check.equal(keyPress(Code.returnKey, "\r"), .confirm)
        Check.equal(keyPress(Code.keypadEnter), .confirm)
        Check.equal(keyPress(Code.leftArrow), .previous)
        Check.equal(keyPress(Code.upArrow), .previous)
        Check.equal(keyPress(Code.pageUp), .previous)
        Check.equal(keyPress(Code.delete), .deleteBackward)
        Check.equal(keyPress(Code.forwardDelete), .deleteBackward)
        Check.equal(keyPress(Code.home), .first)
        Check.equal(keyPress(Code.end), .last)
        Check.equal(keyPress(Code.escape), .escape)
        Check.equal(keyPress(18, "1"), .digit(1))
        Check.equal(keyPress(83, "1"), .digit(1), "keypad digit")
        Check.equal(keyPress(29, "0"), .digit(0))
        Check.equal(keyPress(11, "b"), .toggleBlack)
        Check.equal(keyPress(11, "B", shift: true), .toggleBlack)
        Check.equal(keyPress(47, "."), .toggleBlack)
        Check.equal(keyPress(13, "w"), .toggleWhite)
        Check.equal(keyPress(43, ","), .toggleWhite)
        Check.equal(keyPress(35, "p"), .togglePresenterView)
        Check.equal(keyPress(7, "x"), nil)
        Check.equal(keyPress(0, "é"), nil)
        Check.equal(keyPress(0, "٣"), nil, "non-ASCII digits are not slide numbers")
        Check.equal(keyPress(Code.tab), nil, "Tab is left alone")
        Check.equal(keyPress(Code.rightArrow, command: true), nil, "⌘ keys go to the menus")
        Check.equal(keyPress(Code.rightArrow, control: true), nil)
        Check.equal(keyPress(11, "b", command: true), nil)
        Check.equal(keyPress(Code.rightArrow, option: true), .next, "⌥ does not matter")
        Check.equal(keyPress(Code.returnKey, option: true, command: true), .end, "⌥⌘Return ends")
        Check.equal(keyPress(Code.keypadEnter, option: true, command: true), .end)
        Check.equal(keyPress(Code.returnKey, command: true), nil)
    }

    await Check.suite("Presentation: timer") {
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        var timer = PresentationTimer()
        Check.expect(!timer.isRunning)
        Check.equal(timer.elapsed(at: t0), 0)
        timer.start(at: t0)
        Check.expect(timer.isRunning)
        Check.equal(timer.elapsed(at: t0 + 65), 65)
        timer.pause(at: t0 + 65)
        Check.expect(!timer.isRunning)
        Check.equal(timer.elapsed(at: t0 + 500), 65, "paused time does not count")
        timer.start(at: t0 + 100)
        Check.equal(timer.elapsed(at: t0 + 110), 75)
        timer.start(at: t0 + 105)
        Check.equal(timer.elapsed(at: t0 + 110), 75, "start while running changes nothing")
        timer.toggle(at: t0 + 120)
        Check.expect(!timer.isRunning)
        Check.equal(timer.elapsed(at: t0 + 999), 85)
        timer.pause(at: t0 + 130)
        Check.equal(timer.elapsed(at: t0 + 999), 85, "pause while paused changes nothing")
        timer.reset(at: t0 + 130)
        Check.equal(timer.elapsed(at: t0 + 140), 0)
        Check.expect(!timer.isRunning, "a paused timer stays paused after reset")
        timer.toggle(at: t0 + 140)
        timer.reset(at: t0 + 150)
        Check.expect(timer.isRunning, "a running timer keeps running after reset")
        Check.equal(timer.elapsed(at: t0 + 160), 10)
        Check.equal(timer.elapsed(at: t0), 0, "a clock going backwards never gives negative time")

        Check.equal(PresentationTimer.format(0), "00:00")
        Check.equal(PresentationTimer.format(5.9), "00:05")
        Check.equal(PresentationTimer.format(65), "01:05")
        Check.equal(PresentationTimer.format(3599), "59:59")
        Check.equal(PresentationTimer.format(3600), "1:00:00")
        Check.equal(PresentationTimer.format(3723), "1:02:03")
        Check.equal(PresentationTimer.format(36000), "10:00:00")
        Check.equal(PresentationTimer.format(-4), "00:00")
        Check.equal(PresentationTimer.format(.infinity), "00:00")
        Check.equal(PresentationTimer.format(.nan), "00:00")
    }
}

private func geometryChecks() async {
    await Check.suite("Presentation: Beamer notes split") {
        let mm: CGFloat = 72 / 25.4
        let slide43 = CGSize(width: 128 * mm, height: 96 * mm)
        let notes43 = CGSize(width: 256 * mm, height: 96 * mm)
        let slide169 = CGSize(width: 160 * mm, height: 90 * mm)
        let notes169 = CGSize(width: 320 * mm, height: 90 * mm)
        let notes54 = CGSize(width: 250 * mm, height: 100 * mm)
        let bottom169 = CGSize(width: 160 * mm, height: 180 * mm)
        let a4 = CGSize(width: 595, height: 842)

        Check.expect(!SlideGeometry.isDoubleWidth(slide43))
        Check.expect(!SlideGeometry.isDoubleWidth(slide169))
        Check.expect(SlideGeometry.isDoubleWidth(notes43))
        Check.expect(SlideGeometry.isDoubleWidth(notes169))
        Check.expect(SlideGeometry.isDoubleWidth(notes54), "5:4 with notes (2.5)")
        Check.expect(!SlideGeometry.isDoubleWidth(.zero))
        Check.expect(SlideGeometry.isDoubleHeight(bottom169))
        Check.expect(!SlideGeometry.isDoubleHeight(slide169))

        Check.equal(SlideGeometry.notesSide(mode: .automatic, pageSize: notes43, hint: nil), .right, "Beamer default")
        Check.equal(SlideGeometry.notesSide(mode: .automatic, pageSize: notes169, hint: .left), .left)
        Check.equal(SlideGeometry.notesSide(mode: .automatic, pageSize: slide169, hint: .right), nil,
                    "the preamble asks for notes but the pages are plain slides")
        Check.equal(SlideGeometry.notesSide(mode: .automatic, pageSize: bottom169, hint: .bottom), .bottom)
        Check.equal(SlideGeometry.notesSide(mode: .automatic, pageSize: a4, hint: nil), nil, "an article is not split")
        Check.equal(SlideGeometry.notesSide(mode: .automatic, pageSize: notes43, hint: .bottom), .right)
        Check.equal(SlideGeometry.notesSide(mode: .right, pageSize: notes43, hint: nil), .right)
        Check.equal(SlideGeometry.notesSide(mode: .left, pageSize: notes43, hint: .right), .left, "the setting wins")
        Check.equal(SlideGeometry.notesSide(mode: .right, pageSize: slide43, hint: nil), nil)
        Check.equal(SlideGeometry.notesSide(mode: .off, pageSize: notes43, hint: .right), nil)

        Check.equal(SlideGeometry.regions(pageSize: notes43, side: .right), SlideRegions(slide: .leftHalf, notes: .rightHalf))
        Check.equal(SlideGeometry.regions(pageSize: notes43, side: .left), SlideRegions(slide: .rightHalf, notes: .leftHalf))
        Check.equal(SlideGeometry.regions(pageSize: bottom169, side: .bottom), SlideRegions(slide: .topHalf, notes: .bottomHalf))
        Check.equal(SlideGeometry.regions(pageSize: bottom169, side: .top), SlideRegions(slide: .bottomHalf, notes: .topHalf))
        Check.equal(SlideGeometry.regions(pageSize: slide43, side: .right), SlideRegions(slide: .whole, notes: nil),
                    "an appended full-size page is shown whole")
        Check.equal(SlideGeometry.regions(pageSize: notes43, side: nil), SlideRegions(slide: .whole, notes: nil))

        Check.equal(PageRegion.whole.unitRect, CGRect(x: 0, y: 0, width: 1, height: 1))
        Check.equal(PageRegion.rightHalf.unitRect, CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
        Check.equal(PageRegion.topHalf.unitRect, CGRect(x: 0, y: 0.5, width: 1, height: 0.5))
        Check.equal(PageRegion.bottomHalf.unitRect, CGRect(x: 0, y: 0, width: 1, height: 0.5))
        Check.equal(PageRegion.leftHalf.size(onPage: CGSize(width: 800, height: 300)), CGSize(width: 400, height: 300))
        let half = PageRegion.leftHalf.size(onPage: notes43)
        Check.expect(abs(half.width - slide43.width) < 0.001 && abs(half.height - slide43.height) < 0.001,
                     "the slide half of a 4:3 notes page is a 4:3 slide")

        let deck = SlideDeck(generation: 1, pages: [SlidePageInfo(size: notes43), SlidePageInfo(size: slide43)],
                             notesSide: .right)
        Check.expect(deck.hasNotes)
        Check.equal(deck.region(.slide, ofPage: 0), .leftHalf)
        Check.equal(deck.region(.notes, ofPage: 0), .rightHalf)
        Check.equal(deck.region(.slide, ofPage: 1), .whole)
        Check.equal(deck.region(.notes, ofPage: 1), nil)
        Check.equal(deck.region(.slide, ofPage: 2), nil)
        Check.equal(deck.size(of: .notes, ofPage: 7), nil)
        Check.expect(!SlideDeck.empty.hasNotes)
    }

    await Check.suite("Presentation: aspect fit and pixel sizes") {
        Check.equal(SlideGeometry.aspectFit(CGSize(width: 16, height: 9), in: CGRect(x: 0, y: 0, width: 1600, height: 1200)),
                    CGRect(x: 0, y: 150, width: 1600, height: 900), "letterbox")
        Check.equal(SlideGeometry.aspectFit(CGSize(width: 4, height: 3), in: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
                    CGRect(x: 240, y: 0, width: 1440, height: 1080), "pillarbox")
        Check.equal(SlideGeometry.aspectFit(CGSize(width: 4, height: 3), in: CGRect(x: 100, y: 50, width: 400, height: 300)),
                    CGRect(x: 100, y: 50, width: 400, height: 300))
        Check.equal(SlideGeometry.aspectFit(CGSize(width: 16, height: 9), in: CGRect(x: 10, y: 20, width: 100, height: 0)), .zero)
        Check.equal(SlideGeometry.aspectFit(.zero, in: CGRect(x: 0, y: 0, width: 100, height: 100)), .zero)
        let snapped = SlideGeometry.aspectFit(CGSize(width: 16, height: 9), in: CGRect(x: 0, y: 0, width: 100.3, height: 100), scale: 2)
        Check.expect([snapped.minX, snapped.minY, snapped.width, snapped.height].allSatisfy { ($0 * 2).rounded() == $0 * 2 },
                     "snapped to the pixel grid: \(snapped)")
        Check.expect(SlideGeometry.pixelSize(for: CGSize(width: 100, height: 50), scale: 2) == (200, 100))
        Check.expect(SlideGeometry.pixelSize(for: CGSize(width: 10000, height: 5000), scale: 2) == (8192, 4096),
                     "capped at 8192 px")
        Check.expect(SlideGeometry.pixelSize(for: CGSize(width: 0, height: 5), scale: 2) == (0, 0))
        Check.expect(SlideGeometry.pixelSize(for: CGSize(width: 0.1, height: 0.1), scale: 1) == (1, 1))
    }

    await Check.suite("Presentation: displays") {
        let builtIn = PresentationScreen(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), isBuiltIn: true,
                                         name: "Built-in Retina Display")
        let projector = PresentationScreen(id: 2, frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080),
                                           isBuiltIn: false, name: "Projector")
        let monitor = PresentationScreen(id: 3, frame: CGRect(x: -2560, y: 0, width: 2560, height: 1440),
                                         isBuiltIn: false, name: "Monitor")
        typealias Planner = PresentationScreenPlanner
        Check.equal(Planner.plan(screens: [], preferredPresenter: nil, swapped: false), nil)
        Check.equal(Planner.plan(screens: [builtIn], preferredPresenter: nil, swapped: false),
                    PresentationScreenPlan(audience: 1, presenter: nil), "one display")
        Check.equal(Planner.plan(screens: [projector], preferredPresenter: 2, swapped: true),
                    PresentationScreenPlan(audience: 2, presenter: nil), "nothing to swap")
        Check.equal(Planner.plan(screens: [builtIn, projector], preferredPresenter: nil, swapped: false),
                    PresentationScreenPlan(audience: 2, presenter: 1), "presenter on the laptop")
        Check.equal(Planner.plan(screens: [projector, builtIn], preferredPresenter: 2, swapped: false),
                    PresentationScreenPlan(audience: 2, presenter: 1), "the built-in display wins")
        Check.equal(Planner.plan(screens: [builtIn, projector], preferredPresenter: nil, swapped: true),
                    PresentationScreenPlan(audience: 1, presenter: 2), "swapped")
        Check.equal(Planner.plan(screens: [monitor, projector], preferredPresenter: 2, swapped: false),
                    PresentationScreenPlan(audience: 3, presenter: 2), "no built-in: the project window's display")
        Check.equal(Planner.plan(screens: [monitor, projector], preferredPresenter: nil, swapped: false),
                    PresentationScreenPlan(audience: 2, presenter: 3))
        Check.equal(Planner.plan(screens: [monitor, projector], preferredPresenter: 99, swapped: false),
                    PresentationScreenPlan(audience: 2, presenter: 3), "a display that is gone is ignored")
        Check.equal(Planner.plan(screens: [builtIn, projector, monitor], preferredPresenter: 3, swapped: false),
                    PresentationScreenPlan(audience: 2, presenter: 1), "three displays")
    }
}

private func sourceChecks() async {
    await Check.suite("Presentation: preamble scan") {
        let beamer = PresentationSourceInfo.scan("\\documentclass[aspectratio=169]{beamer}\n\\usetheme{metropolis}\n\\begin{document}\n")
        Check.equal(beamer.documentClass, "beamer")
        Check.expect(beamer.isPresentation)
        Check.equal(beamer.notesSide, nil)

        let commented = PresentationSourceInfo.scan("% \\documentclass{beamer}\n\\documentclass{article}\n")
        Check.equal(commented.documentClass, "article", "commented class ignored")
        Check.expect(!commented.isPresentation)

        let multiline = PresentationSourceInfo.scan("\\documentclass\n  [11pt,\n   handout]\n  { beamer }\n")
        Check.equal(multiline.documentClass, "beamer", "options and braces across lines")
        Check.expect(PresentationSourceInfo.scan("\\documentclass{ltx-talk}\n").isPresentation)
        Check.expect(!PresentationSourceInfo.scan("\\documentclass{beamerposter}\n").isPresentation)
        Check.equal(PresentationSourceInfo.scan("").documentClass, nil)
        Check.equal(PresentationSourceInfo.scan("100\\% sure \\documentclass{beamer}").documentClass, "beamer",
                    "\\% is not a comment")
        Check.equal(PresentationSourceInfo.scan("\\\\% \\documentclass{beamer}").documentClass, nil,
                    "\\\\ followed by % starts a comment")
        Check.equal(PresentationSourceInfo.scan("\r\n\\documentclass{beamer}\r\n\\begin{document}\r\n").documentClass,
                    "beamer", "CRLF")

        Check.equal(PresentationSourceInfo.scan("\\documentclass{beamer}\n\\setbeameroption{show notes on second screen}\n").notesSide,
                    .right, "default side")
        Check.equal(PresentationSourceInfo.scan("\\documentclass{beamer}\n\\setbeameroption{show notes on second screen=left}").notesSide,
                    .left)
        Check.equal(PresentationSourceInfo.scan("\\documentclass{beamer}\n\\setbeameroption{ show notes on second screen = bottom }").notesSide,
                    .bottom)
        Check.equal(PresentationSourceInfo.scan("\\documentclass{beamer}\n%\\setbeameroption{show notes on second screen=left}\n").notesSide,
                    nil, "commented option")
        Check.equal(PresentationSourceInfo.scan("\\documentclass{beamer}\n\\setbeameroption{show notes}\n").notesSide,
                    nil, "notes as separate pages are not a split")
        Check.equal(PresentationSourceInfo.scan("\\documentclass{beamer}\n\\begin{document}\n\\setbeameroption{show notes on second screen=left}").notesSide,
                    nil, "only the preamble counts")
        Check.equal(PresentationSourceInfo.scan("\\documentclass{beamer}\n\\setbeameroption{show notes on second screen=right}\n\\setbeameroption{show notes on second screen=left}\n").notesSide,
                    .left, "the last option wins")
        let long = "\\documentclass{beamer}\n" + String(repeating: "\\usepackage{amsmath}\n", count: 3000)
            + "\\setbeameroption{show notes on second screen=left}\n\\begin{document}\n" + String(repeating: "x\n", count: 20000)
        Check.equal(PresentationSourceInfo.scan(long).notesSide, .left, "long preamble")
    }
}
