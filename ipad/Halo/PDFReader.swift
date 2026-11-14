import SwiftUI
import PDFKit
import PencilKit

@MainActor
struct PDFReader: UIViewRepresentable {
    @ObservedObject var store: StudyStore
    func makeCoordinator() -> Coordinator { Coordinator(store: store) }
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.backgroundColor = UIColor(red: 0.93, green: 0.92, blue: 0.90, alpha: 1)
        view.autoScales = true; view.displayMode = .singlePageContinuous; view.displayDirection = .vertical
        view.pageBreakMargins = UIEdgeInsets(top: 22, left: 22, bottom: 22, right: 22)
        view.pageOverlayViewProvider = context.coordinator
        // PDFKit delivers interaction to page overlays in markup mode. Its ancestor
        // scroll view still handles finger navigation over those overlays.
        view.isInMarkupMode = true
        context.coordinator.view = view
        context.coordinator.observe(view)
        store.ink = context.coordinator
        return view
    }
    func updateUIView(_ view: PDFView, context: Context) {
        let coordinator = context.coordinator
        coordinator.updating = true
        defer { coordinator.updating = false }
        if view.document !== store.pdf {
            coordinator.clearOverlays(); coordinator.lastNavigatedPage = nil; view.document = store.pdf; view.autoScales = true
            // PDFKit ignores go(to:) until the new document has been laid out, so restore the saved page a turn later.
            let saved = store.pageIndex
            DispatchQueue.main.async { [weak view, weak store] in
                guard let view, let store, view.document === store.pdf, store.pageIndex == saved, saved > 0, let page = store.pdf?.page(at: saved) else { return }
                view.go(to: page)
            }
        }
        if coordinator.lastNavigatedPage != store.pageIndex, let page = store.pdf?.page(at: store.pageIndex) {
            coordinator.lastNavigatedPage = store.pageIndex; view.go(to: page)
        }
        coordinator.updateOverlays()
    }
    static func dismantleUIView(_ view: PDFView, coordinator: Coordinator) { coordinator.stopObserving() }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency PDFPageOverlayViewProvider, ReaderControlling {
        let store: StudyStore
        weak var view: PDFView?
        var updating = false
        var lastNavigatedPage: Int?
        var overlays: [Int: PageOverlay] = [:]
        private var observers: [NSObjectProtocol] = []
        private var scrollObservation: NSKeyValueObservation?
        private weak var configuredScrollView: UIScrollView?
        private var navigationTouchTypes: [NSNumber] = []
        private var navigationMinimumTouches = 1
        private let toolPicker = PKToolPicker()
        init(store: StudyStore) { self.store = store }

        func observe(_ view: PDFView) {
            observers.append(NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.updating, let document = self.view?.document, let page = self.view?.currentPage else { return }
                    guard let scroll = self.scrollView, scroll.isDragging || scroll.isDecelerating || scroll.isTracking else { return }
                    let index = document.index(for: page)
                    self.lastNavigatedPage = index
                    self.store.changePage(index); self.updateOverlays()
                }
            })
            observers.append(NotificationCenter.default.addObserver(forName: .PDFViewScaleChanged, object: view, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateAnchor() }
            })
            DispatchQueue.main.async { [weak self] in self?.attachScrollObserver() }
        }
        private var scrollView: UIScrollView? {
            var ancestor = view?.documentView?.superview
            while let candidate = ancestor { if let scroll = candidate as? UIScrollView { return scroll }; ancestor = candidate.superview }
            return nil
        }
        private func attachScrollObserver() {
            guard let scroll = scrollView else { return }
            configureScrolling(scroll)
            guard scrollObservation == nil else { return }
            scrollObservation = scroll.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.updateAnchor() }
            }
        }
        private func configureScrolling(_ scroll: UIScrollView) {
            if configuredScrollView !== scroll {
                restoreScrolling()
                configuredScrollView = scroll
                navigationTouchTypes = scroll.panGestureRecognizer.allowedTouchTypes
                navigationMinimumTouches = scroll.panGestureRecognizer.minimumNumberOfTouches
            }
            let annotating = store.tool != .read
            // A Pencil stroke belongs to the page, never the navigation pan.
            scroll.panGestureRecognizer.allowedTouchTypes = annotating
                ? navigationTouchTypes.filter { $0.intValue != UITouch.TouchType.stylus.rawValue }
                : navigationTouchTypes
            // Finger circling uses one finger; two fingers still navigate.
            scroll.panGestureRecognizer.minimumNumberOfTouches = store.tool == .circle && store.circleWithFinger
                ? max(2, navigationMinimumTouches) : navigationMinimumTouches
        }
        private func restoreScrolling() {
            configuredScrollView?.panGestureRecognizer.allowedTouchTypes = navigationTouchTypes
            configuredScrollView?.panGestureRecognizer.minimumNumberOfTouches = navigationMinimumTouches
            configuredScrollView = nil
        }
        func stopObserving() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }; observers.removeAll()
            scrollObservation = nil
            restoreScrolling()
            clearOverlays()
        }
        func clearOverlays() {
            for overlay in overlays.values {
                if overlay.canvas.isFirstResponder { toolPicker.setVisible(false, forFirstResponder: overlay.canvas); overlay.canvas.resignFirstResponder() }
                toolPicker.removeObserver(overlay.canvas)
            }
            overlays.removeAll()
        }

        // MARK: overlays
        func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
            guard let index = view.document?.index(for: page), index != NSNotFound else { return nil }
            if let existing = overlays[index] { return existing }
            let overlay = PageOverlay()
            overlay.onLasso = { [weak self] lasso, region in self?.store.circled(lasso, region: region, on: index) }
            overlay.onTapThread = { [weak self] id in self?.store.reopen(id) }
            overlay.onHotspot = { [weak self] in
                guard let self else { return }
                let note = self.store.insight(for: index)?.note ?? ""
                self.store.askAboutPage(index, question: note.isEmpty ? "Walk me through the hard part of this page." : "Walk me through this page. I hear \(note.lowercased()) — why?")
            }
            overlay.onDrawing = { [weak self] data in self?.store.saveDrawing(data, page: index) }
            toolPicker.addObserver(overlay.canvas)
            overlays[index] = overlay; configure(overlay, page: index)
            return overlay
        }
        func pdfView(_ pdfView: PDFView, willDisplayOverlayView overlayView: UIView, for page: PDFPage) {
            updateOverlays()
            attachScrollObserver()
            DispatchQueue.main.async { [weak self, weak overlayView] in
                guard let self, let overlay = overlayView as? PageOverlay,
                      self.store.tool == .write, self.store.pill == .hidden,
                      self.view?.currentPage === page, !overlay.canvas.isFirstResponder else { return }
                self.toolPicker.setVisible(true, forFirstResponder: overlay.canvas)
                overlay.canvas.becomeFirstResponder()
            }
        }
        func updateOverlays() {
            if let scroll = scrollView { configureScrolling(scroll) }
            for (index, overlay) in overlays { configure(overlay, page: index) }
            updateAnchor()
        }
        private func configure(_ overlay: PageOverlay, page: Int) {
            overlay.configure(tool: store.tool, fingerCircles: store.circleWithFinger,
                              sessions: store.sessions(on: page), active: store.selectedSessionID,
                              insight: store.insight(for: page), drawing: store.notes.drawings[page],
                              ticks: store.notes.ticks?[page] ?? [], glance: store.glance?.page == page ? store.glance?.region : nil,
                              pointer: store.pointer?.page == page ? store.pointer : nil)
            let writing = store.tool == .write && page == store.pageIndex && store.pill == .hidden
            if overlay.writing != writing {
                overlay.writing = writing
                toolPicker.setVisible(writing, forFirstResponder: overlay.canvas)
                if writing { overlay.canvas.becomeFirstResponder() } else { overlay.canvas.resignFirstResponder() }
            }
        }

        /// Where the active circle is on screen, so the pill can sit beside it.
        func updateAnchor() {
            guard let view, let session = store.activeSession, let overlay = overlays[session.pageIndex] else {
                if store.anchorFrame != nil { store.anchorFrame = nil }
                return
            }
            let rect: CGRect
            if let region = session.region { rect = overlay.rect(region) }
            else { rect = CGRect(x: overlay.bounds.width * 0.08, y: 10, width: overlay.bounds.width * 0.84, height: 44) }
            let frame = overlay.convert(rect, to: view)
            if store.anchorFrame != frame { store.anchorFrame = frame }
        }

        // MARK: ReaderControlling
        func refresh() { updateOverlays() }
        func revealCircle() {
            updateAnchor()
            guard let view, let scroll = scrollView, let anchor = store.anchorFrame else { return }
            let room = view.bounds.insetBy(dx: 0, dy: 90)
            var shift: CGFloat = 0
            if anchor.maxY > room.maxY { shift = anchor.maxY - room.maxY }
            if anchor.minY - shift < room.minY { shift = anchor.minY - room.minY }
            guard abs(shift) > 1 else { return }
            let top = max(-scroll.adjustedContentInset.top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            let target = min(max(scroll.contentOffset.y + shift, -scroll.adjustedContentInset.top), top)
            UIView.animate(withDuration: 0.3) { scroll.contentOffset.y = target } completion: { _ in self.updateAnchor() }
        }
        /// Scrolls to a search hit and marks it, without snapping back to the top of its page.
        func show(_ selection: PDFSelection?) {
            guard let view else { return }
            guard let selection, let page = selection.pages.first, let document = view.document else { view.highlightedSelections = nil; return }
            let index = document.index(for: page)
            lastNavigatedPage = index
            store.changePage(index)
            selection.color = UIColor(red: 1, green: 0.84, blue: 0.2, alpha: 0.55)
            view.highlightedSelections = [selection]
            view.go(to: selection)
            updateOverlays()
        }
    }
}

/// One per page: the student's circles, their note tabs, and their own handwriting.
@MainActor
final class PageOverlay: UIView, PKCanvasViewDelegate, UIGestureRecognizerDelegate {
    let ink = MarginInkView()
    let canvas = PKCanvasView()
    var writing = false
    var onLasso: (([LassoPoint], PageRegion) -> Void)?
    var onTapThread: ((UUID) -> Void)?
    var onHotspot: (() -> Void)?
    var onDrawing: ((Data) -> Void)?
    private var lassoGesture: UIPanGestureRecognizer!
    private var tapGesture: UITapGestureRecognizer!
    private var mode: ReaderTool = .read
    private var sessions: [StudySession] = []
    private var active: UUID?
    private var points: [CGPoint] = []
    private var lastDrawing: Data?
    private var hydrating = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear; isOpaque = false
        addSubview(ink)
        canvas.backgroundColor = .clear; canvas.isOpaque = false; canvas.isScrollEnabled = false
        canvas.drawingPolicy = .pencilOnly
        canvas.tool = PKInkingTool(.pen, color: UIColor(red: 0.16, green: 0.16, blue: 0.22, alpha: 1), width: 2)
        canvas.delegate = self; addSubview(canvas)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(lasso(_:)))
        pan.maximumNumberOfTouches = 1; pan.minimumNumberOfTouches = 1
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.stylus.rawValue), NSNumber(value: UITouch.TouchType.direct.rawValue)]
        lassoGesture = pan; addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.allowedTouchTypes = pan.allowedTouchTypes
        tap.delegate = self
        tapGesture = tap; addGestureRecognizer(tap)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(tool: ReaderTool, fingerCircles: Bool, sessions: [StudySession], active: UUID?, insight: PageInsight?, drawing: Data?,
                   ticks: [PageRegion] = [], glance: PageRegion? = nil, pointer: PagePointing? = nil) {
        lassoGesture.isEnabled = tool == .circle
        lassoGesture.allowedTouchTypes = fingerCircles
            ? [NSNumber(value: UITouch.TouchType.stylus.rawValue), NSNumber(value: UITouch.TouchType.direct.rawValue)]
            : [NSNumber(value: UITouch.TouchType.stylus.rawValue)]
        tapGesture.isEnabled = tool != .write
        mode = tool; self.sessions = sessions; self.active = active
        if drawing != lastDrawing {
            hydrating = true; lastDrawing = drawing
            canvas.drawing = drawing.flatMap { try? PKDrawing(data: $0) } ?? PKDrawing()
            hydrating = false
        }
        canvas.isUserInteractionEnabled = tool == .write
        ink.render(sessions: sessions, active: active, insight: insight, ticks: ticks, glance: glance, pointer: pointer)
        setNeedsDisplay()
    }
    override func layoutSubviews() { super.layoutSubviews(); ink.frame = bounds; canvas.frame = bounds; setNeedsDisplay() }
    func rect(_ region: PageRegion) -> CGRect { CGRect(x: region.x * bounds.width, y: region.y * bounds.height, width: region.width * bounds.width, height: region.height * bounds.height) }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01, self.point(inside: point, with: event) else { return nil }
        // UIKit can hit-test before event.allTouches contains the new touch.
        // Route by tool here, then filter actual touches in the recognizers and
        // PencilKit's pencilOnly policy. Ancestor gestures retain finger scrolling.
        if mode == .write { return canvas.hitTest(convert(point, to: canvas), with: event) }
        if mode == .circle { return self }
        if let hot = ink.hotspotFrame, hot.insetBy(dx: -6, dy: -6).contains(point) { return self }
        if ink.tab(at: point) != nil { return self }
        if sessions.contains(where: { $0.region.map { rect($0).insetBy(dx: -8, dy: -8).contains(point) } ?? false }) { return self }
        return nil
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === tapGesture else { return true }
        if let hot = ink.hotspotFrame, hot.insetBy(dx: -6, dy: -6).contains(touch.location(in: self)) { return true }
        // A note tab is a deliberate target, so a finger may tap it. Circles stay Pencil-only so fingers can scroll over them.
        if ink.tab(at: touch.location(in: self)) != nil { return true }
        return touch.type == .stylus
    }
    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !hydrating else { return }
        let data = canvasView.drawing.dataRepresentation()
        guard data != lastDrawing else { return }
        lastDrawing = data; onDrawing?(data)
    }
    override func draw(_ rect: CGRect) {
        guard points.count > 1, let context = UIGraphicsGetCurrentContext() else { return }
        context.setStrokeColor(InkPalette.circle.cgColor); context.setLineWidth(3.4); context.setLineCap(.round); context.setLineJoin(.round)
        context.setShadow(offset: .zero, blur: 4, color: InkPalette.circle.withAlphaComponent(0.35).cgColor)
        context.move(to: points[0])
        for i in 1..<(points.count - 1) { context.addQuadCurve(to: CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2), control: points[i]) }
        context.addLine(to: points[points.count - 1])
        context.strokePath()
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        if let hot = ink.hotspotFrame, hot.insetBy(dx: -6, dy: -6).contains(point) { onHotspot?(); return }
        if let id = ink.tab(at: point) { onTapThread?(id); return }
        for session in sessions.reversed() {
            if let region = session.region, rect(region).insetBy(dx: -8, dy: -8).contains(point) { onTapThread?(session.id); return }
        }
    }
    @objc private func lasso(_ gesture: UIPanGestureRecognizer) {
        guard mode == .circle else { return }
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began: points = [point]
        case .changed:
            if let last = points.last, hypot(point.x - last.x, point.y - last.y) >= 2 { points.append(point); setNeedsDisplay() }
        case .ended:
            defer { points = []; setNeedsDisplay() }
            guard points.count >= 6, bounds.width > 0, bounds.height > 0 else { return }
            var minX = CGFloat.infinity, minY = CGFloat.infinity, maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
            for p in points { minX = min(minX, p.x); minY = min(minY, p.y); maxX = max(maxX, p.x); maxY = max(maxY, p.y) }
            let w = maxX - minX, h = maxY - minY
            guard w > 10, h > 8 else { return }
            // A stroke that ends near where it started is a circle. Be forgiving: Pencil strokes rarely close exactly.
            let first = points[0], last = points[points.count - 1]
            guard hypot(first.x - last.x, first.y - last.y) < max(44, hypot(w, h) * 0.5) else { return }
            guard let region = PageRegion.drag(fromX: minX, fromY: minY, toX: maxX, toY: maxY, pageWidth: bounds.width, pageHeight: bounds.height) else { return }
            let stride = max(1, points.count / 60)
            let lasso = points.enumerated().filter { $0.offset % stride == 0 || $0.offset == points.count - 1 }
                .map { LassoPoint(x: $0.element.x / bounds.width, y: $0.element.y / bounds.height) }
            onLasso?(lasso, region)
        case .cancelled, .failed: points = []; setNeedsDisplay()
        default: break
        }
    }
}
