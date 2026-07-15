import QtQuick 2.4
import QtQuick.Controls 2.3
import QtQuick.Controls.Material 2.3
import QtQuick.Window 2.2

Item {
    id: scopeView
    width: 1280
    height: 620

    property string effect: "scope1"
    property bool hasEffect: !!currentEffects[effect] && !!currentEffects[effect]["controls"]
    property string notifyBroadcastEffect: ""
    property bool freeze: boolControlValue("freeze", false)
    property int timebaseIndex: boundedIntControlValue("timebase", 4, 0, timebaseLabels.length - 1)
    property int voltsDivIndex: boundedIntControlValue("volts_div", 2, 0, voltsDivLabels.length - 1)
    property int triggerSource: boundedIntControlValue("trigger_source", 1, 1, 4)
    property int triggerMode: boundedIntControlValue("trigger_mode", 0, 0, triggerModeLabels.length - 1)
    property real triggerLevel: controlValue("trigger_level", 0.0)
    property int viewMode: boundedIntControlValue("view_mode", 0, 0, viewModeLabels.length - 1)
    property int persistenceIndex: boundedIntControlValue("persistence", 2, 0, persistenceLabels.length - 1)
    property int intensityIndex: boundedIntControlValue("intensity", 2, 0, intensityLabels.length - 1)
    property int coupling1: boundedIntControlValue("coupling_1", 0, 0, couplingLabels.length - 1)
    property int coupling2: boundedIntControlValue("coupling_2", 0, 0, couplingLabels.length - 1)
    property int coupling3: boundedIntControlValue("coupling_3", 0, 0, couplingLabels.length - 1)
    property int coupling4: boundedIntControlValue("coupling_4", 0, 0, couplingLabels.length - 1)
    property bool visible1: boolControlValue("visible_1", true)
    property bool visible2: boolControlValue("visible_2", true)
    property bool visible3: boolControlValue("visible_3", true)
    property bool visible4: boolControlValue("visible_4", true)
    property int focusChannel: 0
    property bool showEnvelope: true
    property bool showCursors: false
    property int selectedCursor: 0
    property real cursorTimeA: 0.18
    property real cursorTimeB: 0.68
    property real cursorVoltA: 0.35
    property real cursorVoltB: -0.25
    property var rawTraces: [[], [], [], []]
    property var frameHistory: []
    property var processedTraces: [[], [], [], []]
    property var processedHistory: []
    property var traceStats: [
        {"peak": 0.0, "minimum": 0.0, "maximum": 0.0, "pp": 0.0, "mean": 0.0, "rms": 0.0, "frequency": 0.0},
        {"peak": 0.0, "minimum": 0.0, "maximum": 0.0, "pp": 0.0, "mean": 0.0, "rms": 0.0, "frequency": 0.0},
        {"peak": 0.0, "minimum": 0.0, "maximum": 0.0, "pp": 0.0, "mean": 0.0, "rms": 0.0, "frequency": 0.0},
        {"peak": 0.0, "minimum": 0.0, "maximum": 0.0, "pp": 0.0, "mean": 0.0, "rms": 0.0, "frequency": 0.0}
    ]
    property var holdMarkers: [null, null, null, null]
    property var envelopeCache: [null, null, null, null]
    property var channelColors: ["#28E1B3", "#FFD166", "#FF6B6B", "#6FB6FF"]
    property var dimChannelColors: ["#1B6B59", "#8E7236", "#8A4545", "#436B8A"]
    property var channelLabels: ["CH1", "CH2", "CH3", "CH4"]
    property var timebaseLabels: ["0.5 ms/div", "1 ms/div", "2 ms/div", "5 ms/div", "10 ms/div", "20 ms/div", "50 ms/div", "100 ms/div"]
    property var timebaseMsValues: [0.5, 1.0, 2.0, 5.0, 10.0, 20.0, 50.0, 100.0]
    property var voltsDivLabels: ["0.5 V/div", "1 V/div", "2 V/div", "5 V/div", "10 V/div"]
    property var triggerModeLabels: ["AUTO", "RISE", "FALL"]
    property var viewModeLabels: ["STACK", "OVERLAY", "XY 1-2", "XY 3-4"]
    property var persistenceLabels: ["OFF", "LOW", "MED", "HIGH", "MAX"]
    property var persistenceDepths: [1, 2, 3, 4, 6]
    property var intensityLabels: ["DIM", "SOFT", "MED", "HOT", "MAX"]
    property var intensityAlphas: [0.28, 0.42, 0.58, 0.76, 1.0]
    property var couplingLabels: ["DC", "AC"]
    property var displayGains: [3.2, 2.0, 1.0, 0.45, 0.22]
    property bool hasFrame: rawTraces[0].length > 0 || rawTraces[1].length > 0 || rawTraces[2].length > 0 || rawTraces[3].length > 0
    property bool isXYView: viewMode >= 2

    // Render on a fixed beat instead of on every frame arrival: setFrames() and
    // control changes call requestRender() (sets the flag); the Timer does the
    // single real repaint at ~25 FPS only when something changed. This caps
    // redraw cost and prevents a frame backlog from building up.
    property bool _paintDirty: false
    function requestRender() { _paintDirty = true }

    Timer {
        interval: 40        // ~25 FPS cap; raise once smooth on-device
        repeat: true
        running: true
        onTriggered: {
            if (scopeView._paintDirty) {
                scopeView._paintDirty = false
                chart.requestPaint()
            }
        }
    }
    property int xyStartChannel: viewMode === 2 ? 0 : 2
    property real displayGain: displayGains[Math.max(0, Math.min(displayGains.length - 1, voltsDivIndex))]
    property real traceIntensity: intensityAlphas[Math.max(0, Math.min(intensityAlphas.length - 1, intensityIndex))]
    property real refreshHzEstimate: 0.0
    property double lastFrameAtMs: 0
    property int frameSampleCount: 0

    function controlValue(name, fallback) {
        var effectState = currentEffects[effect]
        if (!effectState || !effectState["controls"] || !effectState["controls"][name]) {
            return fallback
        }

        var value = effectState["controls"][name]["value"]
        return value === undefined || value === null ? fallback : value
    }

    function intControlValue(name, fallback) {
        return Math.round(controlValue(name, fallback))
    }

    function boundedIntControlValue(name, fallback, minValue, maxValue) {
        return Math.max(minValue, Math.min(maxValue, intControlValue(name, fallback)))
    }

    function boolControlValue(name, fallback) {
        return Boolean(controlValue(name, fallback ? 1 : 0))
    }

    function emptyFrames() {
        return [[], [], [], []]
    }

    function makeTraceStats() {
        return {"peak": 0.0, "minimum": 0.0, "maximum": 0.0, "pp": 0.0, "mean": 0.0, "rms": 0.0, "frequency": 0.0}
    }

    function emptyStats() {
        return [makeTraceStats(), makeTraceStats(), makeTraceStats(), makeTraceStats()]
    }

    function normalizeFrames(frames) {
        var normalized = emptyFrames()
        if (!frames) {
            return normalized
        }

        for (var channel = 0; channel < 4; ++channel) {
            if (frames.length > channel && frames[channel]) {
                normalized[channel] = frames[channel]
            }
        }
        return normalized
    }

    function traceLength(frames) {
        var maximum = 0
        for (var channel = 0; channel < 4; ++channel) {
            if (frames.length > channel && frames[channel]) {
                maximum = Math.max(maximum, frames[channel].length)
            }
        }
        return maximum
    }

    function minArrayValue(values) {
        if (!values || values.length === 0) {
            return 0.0
        }
        var minimum = values[0]
        for (var index = 1; index < values.length; ++index) {
            minimum = Math.min(minimum, values[index])
        }
        return minimum
    }

    function maxArrayValue(values) {
        if (!values || values.length === 0) {
            return 0.0
        }
        var maximum = values[0]
        for (var index = 1; index < values.length; ++index) {
            maximum = Math.max(maximum, values[index])
        }
        return maximum
    }

    function channelStats(channel) {
        return (traceStats.length > channel && traceStats[channel]) ? traceStats[channel] : makeTraceStats()
    }

    function persistenceDepth() {
        return persistenceDepths[Math.max(0, Math.min(persistenceDepths.length - 1, persistenceIndex))]
    }

    function visibleWindowMs() {
        return timebaseMsValues[timebaseIndex] * 10.0
    }

    function registerFrameArrival(sampleCount) {
        var now = Date.now()
        frameSampleCount = sampleCount
        if (lastFrameAtMs > 0) {
            var deltaMs = Math.max(1, now - lastFrameAtMs)
            var instantHz = 1000.0 / deltaMs
            refreshHzEstimate = refreshHzEstimate > 0.0 ? (refreshHzEstimate * 0.82) + (instantHz * 0.18) : instantHz
        }
        lastFrameAtMs = now
    }

    function setFrames(frames) {
        rawTraces = normalizeFrames(frames)
        registerFrameArrival(traceLength(rawTraces))

        // Incremental: process ONLY the new frame; reuse the already-processed
        // history frames (shifted) instead of reprocessing all of them every
        // frame. A full reprocess only happens on control changes
        // (rebuildTraceCaches via the coupling/timebase/envelope handlers).
        var limit = persistenceDepth()
        var processedCurrent = emptyFrames()
        var nextStats = emptyStats()
        for (var channel = 0; channel < 4; ++channel) {
            processedCurrent[channel] = processTrace(rawTraces[channel], channel)
            nextStats[channel] = traceStatsFor(processedCurrent[channel])
        }

        var nextRaw = [rawTraces]
        var nextProcessed = [processedCurrent]
        for (var index = 0;
             index < frameHistory.length && index < processedHistory.length && nextRaw.length < limit;
             ++index) {
            nextRaw.push(frameHistory[index])
            nextProcessed.push(processedHistory[index])
        }

        var nextEnvelopeCache = [null, null, null, null]
        var nextHoldMarkers = [null, null, null, null]
        for (channel = 0; channel < 4; ++channel) {
            nextEnvelopeCache[channel] = buildEnvelope(channel, nextProcessed)
            nextHoldMarkers[channel] = buildHoldMarkers(processedCurrent[channel], nextEnvelopeCache[channel])
        }

        frameHistory = nextRaw
        processedHistory = nextProcessed
        processedTraces = processedCurrent
        traceStats = nextStats
        envelopeCache = nextEnvelopeCache
        holdMarkers = nextHoldMarkers
        requestRender()
    }

    function resetTraceState() {
        rawTraces = emptyFrames()
        frameHistory = []
        processedTraces = emptyFrames()
        processedHistory = []
        traceStats = emptyStats()
        holdMarkers = [null, null, null, null]
        envelopeCache = [null, null, null, null]
        refreshHzEstimate = 0.0
        lastFrameAtMs = 0
        frameSampleCount = 0
        requestRender()
    }

    function clearTraces() {
        resetTraceState()
        scopeFrames.clearEffect(effect)
    }

    function disableNotifyBroadcast() {
        if (notifyBroadcastEffect !== "") {
            knobs.set_port_broadcast(notifyBroadcastEffect, "notify", false)
            notifyBroadcastEffect = ""
        }
    }

    function syncNotifyBroadcast() {
        if (hasEffect && notifyBroadcastEffect === effect) {
            return
        }

        disableNotifyBroadcast()
        resetTraceState()

        if (hasEffect) {
            knobs.set_port_broadcast(effect, "notify", true)
            notifyBroadcastEffect = effect
        }
    }

    function refreshHistoryLimit() {
        var next = []
        var limit = persistenceDepth()
        if (hasFrame) {
            next.push(rawTraces)
        }
        for (var index = 0; index < frameHistory.length && next.length < limit; ++index) {
            if (frameHistory[index] !== rawTraces) {
                next.push(frameHistory[index])
            }
        }
        frameHistory = next
        rebuildTraceCaches()
    }

    function toggleFreeze() {
        knobs.ui_knob_change(effect, "freeze", freeze ? 0 : 1)
    }

    function setIntControl(name, value) {
        knobs.ui_knob_change(effect, name, Number(value))
    }

    function setBoolControl(name, value) {
        knobs.ui_knob_change(effect, name, value ? 1 : 0)
    }

    function stepIntControl(name, currentValue, minValue, maxValue, delta) {
        var next = Math.max(minValue, Math.min(maxValue, currentValue + delta))
        setIntControl(name, next)
    }

    function couplingMode(channel) {
        if (channel === 0) {
            return coupling1
        }
        if (channel === 1) {
            return coupling2
        }
        if (channel === 2) {
            return coupling3
        }
        return coupling4
    }

    function couplingName(channel) {
        return "coupling_" + (channel + 1)
    }

    function channelVisible(channel) {
        if (channel === 0) {
            return visible1
        }
        if (channel === 1) {
            return visible2
        }
        if (channel === 2) {
            return visible3
        }
        return visible4
    }

    function visibilityName(channel) {
        return "visible_" + (channel + 1)
    }

    function visibleCount() {
        var count = 0
        for (var channel = 0; channel < 4; ++channel) {
            if (channelVisible(channel)) {
                count += 1
            }
        }
        return count
    }

    function clampUnit(value) {
        return Math.max(-1.0, Math.min(1.0, value))
    }

    function clampFraction(value) {
        return Math.max(0.0, Math.min(1.0, value))
    }

    function toggleChannelVisible(channel) {
        setBoolControl(visibilityName(channel), !channelVisible(channel))
    }

    function setCursorValue(name, value, signedRange) {
        scopeView[name] = signedRange ? clampUnit(value) : clampFraction(value)
    }

    function stepCursorValue(name, delta, signedRange) {
        setCursorValue(name, scopeView[name] + delta, signedRange)
    }

    function cursorSignalValue(value) {
        return displayGain <= 0.0 ? 0.0 : value / displayGain
    }

    function cursorAbsoluteTimeMs(value) {
        return clampFraction(value) * visibleWindowMs()
    }

    function cursorAbsoluteVoltage(value) {
        return cursorSignalValue(clampUnit(value))
    }

    function cursorDeltaTimeMs() {
        return Math.abs(cursorTimeB - cursorTimeA) * visibleWindowMs()
    }

    function cursorDeltaVoltage() {
        return Math.abs(cursorSignalValue(cursorVoltB) - cursorSignalValue(cursorVoltA))
    }

    function cursorFrequencyHz() {
        var deltaMs = cursorDeltaTimeMs()
        return deltaMs > 0.0 ? 1000.0 / deltaMs : 0.0
    }

    function updateSelectedCursorFromPlot(x, y, drawWidth, drawHeight) {
        if (drawWidth <= 0 || drawHeight <= 0) {
            return
        }
        var nextTime = clampFraction(x / drawWidth)
        var focusTop = viewMode === 1 ? 0.0 : (drawHeight / 4.0) * focusChannel
        var focusHeight = viewMode === 1 ? drawHeight : drawHeight / 4.0
        var amplitude = focusHeight * 0.37
        var centerY = focusTop + focusHeight / 2.0
        var nextVolt = amplitude <= 0.0 ? 0.0 : clampUnit((centerY - y) / amplitude)

        if (selectedCursor === 0) {
            cursorTimeA = nextTime
            cursorVoltA = nextVolt
        } else {
            cursorTimeB = nextTime
            cursorVoltB = nextVolt
        }
        requestRender()
    }

    function buildEnvelope(channel, historyFrames) {
        if (!showEnvelope || historyFrames.length < 2) {
            return null
        }

        var sampleCount = 0
        for (var frameIndex = 0; frameIndex < historyFrames.length; ++frameIndex) {
            if (historyFrames[frameIndex].length > channel && historyFrames[frameIndex][channel]) {
                sampleCount = Math.max(sampleCount, historyFrames[frameIndex][channel].length)
            }
        }

        if (sampleCount === 0) {
            return null
        }

        var minimums = []
        var maximums = []
        for (var sampleIndex = 0; sampleIndex < sampleCount; ++sampleIndex) {
            minimums.push(9999.0)
            maximums.push(-9999.0)
        }

        var hadData = false
        for (frameIndex = 0; frameIndex < historyFrames.length; ++frameIndex) {
            var trace = historyFrames[frameIndex][channel]
            for (sampleIndex = 0; trace && sampleIndex < trace.length; ++sampleIndex) {
                minimums[sampleIndex] = Math.min(minimums[sampleIndex], trace[sampleIndex])
                maximums[sampleIndex] = Math.max(maximums[sampleIndex], trace[sampleIndex])
                hadData = true
            }
        }

        return hadData ? {"minimums": minimums, "maximums": maximums} : null
    }

    function buildHoldMarkers(trace, envelope) {
        if ((!trace || trace.length === 0) && !envelope) {
            return null
        }

        var minimum = minValue(trace)
        var maximum = maxValue(trace)
        if (envelope) {
            minimum = Math.min(minimum, minArrayValue(envelope.minimums))
            maximum = Math.max(maximum, maxArrayValue(envelope.maximums))
        }
        return {"minimum": minimum, "maximum": maximum}
    }

    function rebuildTraceCaches() {
        var nextCurrent = emptyFrames()
        var nextHistory = []
        var nextStats = emptyStats()
        var nextEnvelopeCache = [null, null, null, null]
        var nextHoldMarkers = [null, null, null, null]

        for (var channel = 0; channel < 4; ++channel) {
            nextCurrent[channel] = processTrace(rawTraces[channel], channel)
            nextStats[channel] = traceStatsFor(nextCurrent[channel])
        }

        for (var frameIndex = 0; frameIndex < frameHistory.length; ++frameIndex) {
            var sourceFrame = frameHistory[frameIndex]
            var processedFrame = emptyFrames()
            for (channel = 0; channel < 4; ++channel) {
                processedFrame[channel] = processTrace(sourceFrame[channel], channel)
            }
            nextHistory.push(processedFrame)
        }

        for (channel = 0; channel < 4; ++channel) {
            nextEnvelopeCache[channel] = buildEnvelope(channel, nextHistory)
            nextHoldMarkers[channel] = buildHoldMarkers(nextCurrent[channel], nextEnvelopeCache[channel])
        }

        processedTraces = nextCurrent
        processedHistory = nextHistory
        traceStats = nextStats
        envelopeCache = nextEnvelopeCache
        holdMarkers = nextHoldMarkers
        requestRender()
    }

    function processTrace(trace, channel) {
        var output = []
        if (!trace || trace.length === 0) {
            return output
        }

        var offset = 0.0
        if (couplingMode(channel) === 1) {
            for (var index = 0; index < trace.length; ++index) {
                offset += trace[index]
            }
            offset /= trace.length
        }

        for (index = 0; index < trace.length; ++index) {
            output.push(trace[index] - offset)
        }
        return output
    }

    function currentTrace(channel) {
        return (processedTraces.length > channel && processedTraces[channel]) ? processedTraces[channel] : []
    }

    function historyEnvelope(channel) {
        return showEnvelope && envelopeCache.length > channel ? envelopeCache[channel] : null
    }

    function peakValue(trace) {
        var peak = 0.0
        for (var index = 0; index < trace.length; ++index) {
            peak = Math.max(peak, Math.abs(trace[index]))
        }
        return peak
    }

    function minValue(trace) {
        if (trace.length === 0) {
            return 0.0
        }
        var minimum = trace[0]
        for (var index = 1; index < trace.length; ++index) {
            minimum = Math.min(minimum, trace[index])
        }
        return minimum
    }

    function maxValue(trace) {
        if (trace.length === 0) {
            return 0.0
        }
        var maximum = trace[0]
        for (var index = 1; index < trace.length; ++index) {
            maximum = Math.max(maximum, trace[index])
        }
        return maximum
    }

    function ppValue(trace) {
        return maxValue(trace) - minValue(trace)
    }

    function meanValue(trace) {
        if (trace.length === 0) {
            return 0.0
        }
        var total = 0.0
        for (var index = 0; index < trace.length; ++index) {
            total += trace[index]
        }
        return total / trace.length
    }

    function rmsValue(trace) {
        if (trace.length === 0) {
            return 0.0
        }
        var total = 0.0
        for (var index = 0; index < trace.length; ++index) {
            total += trace[index] * trace[index]
        }
        return Math.sqrt(total / trace.length)
    }

    function estimateFrequency(trace) {
        if (!trace || trace.length < 8) {
            return 0.0
        }

        var crossings = []
        for (var index = 1; index < trace.length; ++index) {
            if (trace[index - 1] <= 0.0 && trace[index] > 0.0) {
                crossings.push(index)
            }
        }

        if (crossings.length < 2) {
            return 0.0
        }

        var periodSamples = (crossings[crossings.length - 1] - crossings[0]) / (crossings.length - 1)
        if (periodSamples <= 0.0) {
            return 0.0
        }

        var samplesPerSecond = trace.length / (visibleWindowMs() / 1000.0)
        return samplesPerSecond / periodSamples
    }

    function estimateCorrelation(xTrace, yTrace) {
        var pointCount = Math.min(xTrace ? xTrace.length : 0, yTrace ? yTrace.length : 0)
        if (pointCount < 4) {
            return 0.0
        }

        var meanX = 0.0
        var meanY = 0.0
        for (var index = 0; index < pointCount; ++index) {
            meanX += xTrace[index]
            meanY += yTrace[index]
        }
        meanX /= pointCount
        meanY /= pointCount

        var covariance = 0.0
        var varianceX = 0.0
        var varianceY = 0.0
        for (index = 0; index < pointCount; ++index) {
            var centeredX = xTrace[index] - meanX
            var centeredY = yTrace[index] - meanY
            covariance += centeredX * centeredY
            varianceX += centeredX * centeredX
            varianceY += centeredY * centeredY
        }

        if (varianceX <= 0.0 || varianceY <= 0.0) {
            return 0.0
        }

        return covariance / Math.sqrt(varianceX * varianceY)
    }

    function traceStatsFor(trace) {
        var minimum = minValue(trace)
        var maximum = maxValue(trace)
        return {
            "peak": peakValue(trace),
            "minimum": minimum,
            "maximum": maximum,
            "pp": maximum - minimum,
            "mean": meanValue(trace),
            "rms": rmsValue(trace),
            "frequency": estimateFrequency(trace)
        }
    }

    function formatMetric(value) {
        var absValue = Math.abs(value)
        return absValue >= 10.0 ? value.toFixed(1) : value.toFixed(2)
    }

    function formatTimeMetric(valueMs) {
        var absValue = Math.abs(valueMs)
        if (absValue >= 1000.0) {
            return (valueMs / 1000.0).toFixed(absValue >= 10000.0 ? 1 : 2) + " s"
        }
        if (absValue >= 1.0) {
            return valueMs.toFixed(absValue >= 100.0 ? 1 : 2) + " ms"
        }
        return (valueMs * 1000.0).toFixed(absValue >= 0.1 ? 1 : 2) + " us"
    }

    function formatVoltageMetric(value) {
        return formatMetric(value) + " V"
    }

    function formatFrequency(value) {
        if (!value || value < 0.2) {
            return "--"
        }
        if (value >= 1000.0) {
            return (value / 1000.0).toFixed(value >= 10000.0 ? 1 : 2) + " kHz"
        }
        return value.toFixed(value >= 100.0 ? 1 : 2) + " Hz"
    }

    function couplingLabel(channel) {
        return couplingMode(channel) === 1 ? "AC" : "DC"
    }

    function autosetScope() {
        var bestChannel = -1
        var bestPeak = 0.0
        var bestTrace = []

        for (var channel = 0; channel < 4; ++channel) {
            if (!channelVisible(channel)) {
                continue
            }
            var trace = currentTrace(channel)
            var peak = peakValue(trace)
            if (peak > bestPeak) {
                bestPeak = peak
                bestChannel = channel
                bestTrace = trace
            }
        }

        if (bestChannel < 0 || bestPeak <= 0.0001) {
            return
        }

        focusChannel = bestChannel
        setIntControl("trigger_source", bestChannel + 1)
        knobs.ui_knob_change(effect, "trigger_level", meanValue(bestTrace))

        var nextVoltsDiv = displayGains.length - 1
        for (var gainIndex = 0; gainIndex < displayGains.length; ++gainIndex) {
            if (bestPeak * displayGains[gainIndex] <= 0.78) {
                nextVoltsDiv = gainIndex
                break
            }
        }
        setIntControl("volts_div", nextVoltsDiv)

        var estimatedHz = estimateFrequency(bestTrace)
        if (estimatedHz > 0.2) {
            var desiredWindow = (1000.0 / estimatedHz) * 4.0
            var bestTimebase = 0
            var bestError = 999999.0
            for (var timeIndex = 0; timeIndex < timebaseMsValues.length; ++timeIndex) {
                var windowMs = timebaseMsValues[timeIndex] * 10.0
                var error = Math.abs(windowMs - desiredWindow)
                if (error < bestError) {
                    bestError = error
                    bestTimebase = timeIndex
                }
            }
            setIntControl("timebase", bestTimebase)
        }

        var gain = displayGains[nextVoltsDiv]
        cursorTimeA = 0.18
        cursorTimeB = 0.68
        cursorVoltA = clampUnit(maxValue(bestTrace) * gain)
        cursorVoltB = clampUnit(minValue(bestTrace) * gain)
    }

    function triggerGuideY(top, rowHeight) {
        var centerY = top + rowHeight / 2
        var amplitude = rowHeight * 0.37
        return centerY - (Math.max(-1.0, Math.min(1.0, triggerLevel * displayGain)) * amplitude)
    }

    function drawScopeGrid(ctx, top, rowHeight, drawWidth) {
        ctx.save()
        ctx.strokeStyle = "#172435"
        ctx.lineWidth = 1
        for (var vertical = 0; vertical < 11; ++vertical) {
            var x = (drawWidth / 10) * vertical
            ctx.beginPath()
            ctx.moveTo(x, top)
            ctx.lineTo(x, top + rowHeight)
            ctx.stroke()
        }
        for (var horizontal = 0; horizontal < 5; ++horizontal) {
            var y = top + (rowHeight / 4) * horizontal
            ctx.beginPath()
            ctx.moveTo(0, y)
            ctx.lineTo(drawWidth, y)
            ctx.stroke()
        }
        ctx.strokeStyle = "#2B4865"
        ctx.beginPath()
        ctx.moveTo(0, top + rowHeight / 2)
        ctx.lineTo(drawWidth, top + rowHeight / 2)
        ctx.stroke()
        ctx.restore()
    }

    function drawXYGrid(ctx, left, top, plotWidth, plotHeight) {
        ctx.save()
        var centerX = left + plotWidth / 2
        var centerY = top + plotHeight / 2
        var radius = Math.min(plotWidth, plotHeight) * 0.5

        ctx.fillStyle = "#091018"
        ctx.fillRect(left, top, plotWidth, plotHeight)

        ctx.strokeStyle = "#172435"
        ctx.lineWidth = 1
        for (var vertical = 0; vertical < 9; ++vertical) {
            var x = left + (plotWidth / 8) * vertical
            ctx.beginPath()
            ctx.moveTo(x, top)
            ctx.lineTo(x, top + plotHeight)
            ctx.stroke()
        }
        for (var horizontal = 0; horizontal < 9; ++horizontal) {
            var y = top + (plotHeight / 8) * horizontal
            ctx.beginPath()
            ctx.moveTo(left, y)
            ctx.lineTo(left + plotWidth, y)
            ctx.stroke()
        }
        if (ctx.setLineDash) {
            ctx.setLineDash([4, 6])
        }
        ctx.strokeStyle = "#122131"
        ctx.beginPath()
        ctx.moveTo(left, top)
        ctx.lineTo(left + plotWidth, top + plotHeight)
        ctx.stroke()
        ctx.beginPath()
        ctx.moveTo(left + plotWidth, top)
        ctx.lineTo(left, top + plotHeight)
        ctx.stroke()
        if (ctx.setLineDash) {
            ctx.setLineDash([])
        }
        ctx.strokeStyle = "#163044"
        for (var ring = 1; ring <= 4; ++ring) {
            ctx.globalAlpha = ring === 4 ? 0.75 : 0.35
            ctx.beginPath()
            ctx.arc(centerX, centerY, radius * (ring / 4.0), 0, Math.PI * 2)
            ctx.stroke()
        }
        ctx.globalAlpha = 1.0
        ctx.strokeStyle = "#2B4865"
        ctx.beginPath()
        ctx.moveTo(centerX, top)
        ctx.lineTo(centerX, top + plotHeight)
        ctx.stroke()
        ctx.beginPath()
        ctx.moveTo(left, centerY)
        ctx.lineTo(left + plotWidth, centerY)
        ctx.stroke()
        ctx.beginPath()
        ctx.arc(centerX, centerY, 4, 0, Math.PI * 2)
        ctx.stroke()
        ctx.restore()
    }

    function drawTriggerGuide(ctx, top, rowHeight, color, drawWidth) {
        if (triggerMode === 0) {
            return
        }

        var y = triggerGuideY(top, rowHeight)
        ctx.save()
        ctx.strokeStyle = color
        ctx.fillStyle = color
        ctx.lineWidth = 1
        if (ctx.setLineDash) {
            ctx.setLineDash([6, 6])
        }
        ctx.beginPath()
        ctx.moveTo(0, y)
        ctx.lineTo(drawWidth, y)
        ctx.stroke()
        if (ctx.setLineDash) {
            ctx.setLineDash([])
        }
        ctx.beginPath()
        ctx.moveTo(0, y)
        ctx.lineTo(10, y - 6)
        ctx.lineTo(10, y + 6)
        ctx.closePath()
        ctx.fill()
        ctx.font = "12px " + mainFont.name
        ctx.fillText(triggerLevel.toFixed(2), drawWidth - 44, Math.max(14, y - 4))
        ctx.restore()
    }

    function drawTimeRuler(ctx, drawWidth, drawHeight) {
        ctx.save()
        ctx.strokeStyle = "#1D2B3B"
        ctx.lineWidth = 1
        ctx.beginPath()
        ctx.moveTo(0, drawHeight - 18)
        ctx.lineTo(drawWidth, drawHeight - 18)
        ctx.stroke()

        var labels = ["0", (visibleWindowMs() * 0.5).toFixed(1) + " ms", visibleWindowMs().toFixed(1) + " ms"]
        var positions = [10, drawWidth * 0.5 - 26, drawWidth - 62]
        ctx.fillStyle = "#607286"
        ctx.font = "12px " + mainFont.name
        for (var labelIndex = 0; labelIndex < labels.length; ++labelIndex) {
            ctx.fillText(labels[labelIndex], positions[labelIndex], drawHeight - 6)
        }

        ctx.font = "11px " + mainFont.name
        ctx.fillStyle = "#4D657B"
        if (frameSampleCount > 0) {
            ctx.fillText(frameSampleCount + " pts", 10, drawHeight - 24)
        }
        if (refreshHzEstimate > 0.0) {
            var refreshText = refreshHzEstimate.toFixed(1) + " Hz"
            var refreshWidth = ctx.measureText ? ctx.measureText(refreshText).width : refreshText.length * 7
            ctx.fillText(refreshText, drawWidth - refreshWidth - 8, drawHeight - 24)
        }
        ctx.restore()
    }

    function drawScopeEnvelope(ctx, envelope, top, rowHeight, color, alpha, drawWidth) {
        if (!envelope || envelope.minimums.length < 2 || envelope.maximums.length < 2) {
            return
        }

        var centerY = top + rowHeight / 2
        var amplitude = rowHeight * 0.37
        ctx.save()
        ctx.fillStyle = color
        ctx.globalAlpha = alpha * 0.12
        ctx.beginPath()
        for (var index = 0; index < envelope.maximums.length; ++index) {
            var x = envelope.maximums.length === 1 ? drawWidth / 2 : (drawWidth * index) / (envelope.maximums.length - 1)
            var y = centerY - (clampUnit(envelope.maximums[index] * displayGain) * amplitude)
            if (index === 0) {
                ctx.moveTo(x, y)
            } else {
                ctx.lineTo(x, y)
            }
        }
        for (index = envelope.minimums.length - 1; index >= 0; --index) {
            x = envelope.minimums.length === 1 ? drawWidth / 2 : (drawWidth * index) / (envelope.minimums.length - 1)
            y = centerY - (clampUnit(envelope.minimums[index] * displayGain) * amplitude)
            ctx.lineTo(x, y)
        }
        ctx.closePath()
        ctx.fill()
        ctx.restore()
    }

    function drawScopeTrace(ctx, trace, top, rowHeight, color, alpha, drawWidth) {
        var centerY = top + rowHeight / 2
        var amplitude = rowHeight * 0.37

        if (trace.length === 0) {
            return
        }

        ctx.save()
        ctx.globalAlpha = alpha * 0.18
        ctx.strokeStyle = color
        ctx.lineWidth = 7
        ctx.lineJoin = "round"
        ctx.lineCap = "round"
        ctx.beginPath()
        for (var index = 0; index < trace.length; ++index) {
            var x = trace.length === 1 ? drawWidth / 2 : (drawWidth * index) / (trace.length - 1)
            var y = centerY - (Math.max(-1.0, Math.min(1.0, trace[index] * displayGain)) * amplitude)
            if (index === 0) {
                ctx.moveTo(x, y)
            } else {
                ctx.lineTo(x, y)
            }
        }
        ctx.stroke()

        ctx.globalAlpha = alpha
        ctx.lineWidth = 2.1
        ctx.beginPath()
        for (index = 0; index < trace.length; ++index) {
            x = trace.length === 1 ? drawWidth / 2 : (drawWidth * index) / (trace.length - 1)
            y = centerY - (Math.max(-1.0, Math.min(1.0, trace[index] * displayGain)) * amplitude)
            if (index === 0) {
                ctx.moveTo(x, y)
            } else {
                ctx.lineTo(x, y)
            }
        }
        ctx.stroke()

        ctx.globalAlpha = Math.min(1.0, alpha + 0.18)
        ctx.lineWidth = 0.9
        ctx.beginPath()
        for (index = 0; index < trace.length; ++index) {
            x = trace.length === 1 ? drawWidth / 2 : (drawWidth * index) / (trace.length - 1)
            y = centerY - (Math.max(-1.0, Math.min(1.0, trace[index] * displayGain)) * amplitude)
            if (index === 0) {
                ctx.moveTo(x, y)
            } else {
                ctx.lineTo(x, y)
            }
        }
        ctx.stroke()
        ctx.restore()
    }

    function drawXYTrace(ctx, xTrace, yTrace, left, top, plotWidth, plotHeight, color, alpha) {
        var pointCount = Math.min(xTrace.length, yTrace.length)
        if (pointCount < 2) {
            return
        }

        ctx.save()
        ctx.strokeStyle = color
        ctx.lineJoin = "round"
        ctx.lineCap = "round"

        ctx.globalAlpha = alpha * 0.18
        ctx.lineWidth = 7
        ctx.beginPath()
        for (var index = 0; index < pointCount; ++index) {
            var x = left + ((Math.max(-1.0, Math.min(1.0, xTrace[index] * displayGain)) + 1.0) * 0.5 * plotWidth)
            var y = top + plotHeight - ((Math.max(-1.0, Math.min(1.0, yTrace[index] * displayGain)) + 1.0) * 0.5 * plotHeight)
            if (index === 0) {
                ctx.moveTo(x, y)
            } else {
                ctx.lineTo(x, y)
            }
        }
        ctx.stroke()

        ctx.globalAlpha = alpha
        ctx.lineWidth = 2.1
        ctx.beginPath()
        for (index = 0; index < pointCount; ++index) {
            x = left + ((Math.max(-1.0, Math.min(1.0, xTrace[index] * displayGain)) + 1.0) * 0.5 * plotWidth)
            y = top + plotHeight - ((Math.max(-1.0, Math.min(1.0, yTrace[index] * displayGain)) + 1.0) * 0.5 * plotHeight)
            if (index === 0) {
                ctx.moveTo(x, y)
            } else {
                ctx.lineTo(x, y)
            }
        }
        ctx.stroke()

        ctx.globalAlpha = Math.min(1.0, alpha + 0.18)
        ctx.lineWidth = 0.9
        ctx.beginPath()
        for (index = 0; index < pointCount; ++index) {
            x = left + ((Math.max(-1.0, Math.min(1.0, xTrace[index] * displayGain)) + 1.0) * 0.5 * plotWidth)
            y = top + plotHeight - ((Math.max(-1.0, Math.min(1.0, yTrace[index] * displayGain)) + 1.0) * 0.5 * plotHeight)
            if (index === 0) {
                ctx.moveTo(x, y)
            } else {
                ctx.lineTo(x, y)
            }
        }
        ctx.stroke()

        ctx.fillStyle = color
        ctx.globalAlpha = Math.min(1.0, alpha + 0.15)
        ctx.beginPath()
        ctx.arc(x, y, 2.8, 0, Math.PI * 2)
        ctx.fill()
        ctx.restore()
    }

    function drawHoldMarkers(ctx, top, rowHeight, markers, color, drawWidth, offset) {
        if (!markers) {
            return
        }

        var centerY = top + rowHeight / 2
        var amplitude = rowHeight * 0.37
        var rightOffset = offset === undefined ? 0 : offset
        var markerX = drawWidth - 4 - rightOffset
        var maxY = centerY - (clampUnit(markers.maximum * displayGain) * amplitude)
        var minY = centerY - (clampUnit(markers.minimum * displayGain) * amplitude)

        ctx.save()
        ctx.strokeStyle = color
        ctx.fillStyle = color
        ctx.lineWidth = 1.2
        ctx.globalAlpha = 0.18
        ctx.fillRect(drawWidth - 10 - rightOffset, Math.min(maxY, minY), 6, Math.abs(maxY - minY))
        ctx.globalAlpha = 0.95

        ctx.beginPath()
        ctx.moveTo(markerX, maxY)
        ctx.lineTo(drawWidth - 20 - rightOffset, maxY)
        ctx.lineTo(drawWidth - 14 - rightOffset, maxY - 5)
        ctx.stroke()

        ctx.beginPath()
        ctx.moveTo(markerX, minY)
        ctx.lineTo(drawWidth - 20 - rightOffset, minY)
        ctx.lineTo(drawWidth - 14 - rightOffset, minY + 5)
        ctx.stroke()
        ctx.restore()
    }

    function drawBadge(ctx, text, x, y, fillColor, borderColor, textColor, maxWidth, maxHeight) {
        var padding = 6
        var badgeHeight = 16
        var textWidth = ctx.measureText ? ctx.measureText(text).width : text.length * 7
        var badgeWidth = Math.max(26, textWidth + padding * 2)
        var badgeX = Math.max(2, Math.min(maxWidth - badgeWidth - 2, x))
        var badgeY = Math.max(2, Math.min(maxHeight - badgeHeight - 2, y))

        ctx.save()
        ctx.globalAlpha = 0.78
        ctx.fillStyle = fillColor
        ctx.fillRect(badgeX, badgeY, badgeWidth, badgeHeight)
        ctx.globalAlpha = 1.0
        ctx.strokeStyle = borderColor
        ctx.lineWidth = 1
        ctx.strokeRect(badgeX + 0.5, badgeY + 0.5, badgeWidth - 1, badgeHeight - 1)
        ctx.fillStyle = textColor
        ctx.fillText(text, badgeX + padding, badgeY + 11)
        ctx.restore()
    }

    function drawMeasurementCursors(ctx, focusTop, focusHeight, drawWidth, drawHeight) {
        if (!showCursors) {
            return
        }

        var labels = ["A", "B"]
        var colors = ["#90E7D0", "#FFD166"]
        var timeValues = [cursorTimeA, cursorTimeB]
        var voltageValues = [cursorVoltA, cursorVoltB]
        var amplitude = focusHeight * 0.37
        var centerY = focusTop + focusHeight / 2
        var cursorXs = []
        var deltaTop = drawHeight - 32

        ctx.save()
        ctx.font = "11px " + mainFont.name
        for (var index = 0; index < 2; ++index) {
            var cursorX = drawWidth * clampFraction(timeValues[index])
            var cursorY = centerY - (clampUnit(voltageValues[index]) * amplitude)
            cursorXs.push(cursorX)

            ctx.strokeStyle = colors[index]
            ctx.fillStyle = colors[index]
            ctx.lineWidth = selectedCursor === index ? 1.4 : 1.0
            if (ctx.setLineDash) {
                ctx.setLineDash([4, 4])
            }
            ctx.beginPath()
            ctx.moveTo(cursorX, 0)
            ctx.lineTo(cursorX, drawHeight)
            ctx.stroke()
            ctx.beginPath()
            ctx.moveTo(0, cursorY)
            ctx.lineTo(drawWidth, cursorY)
            ctx.stroke()
            if (ctx.setLineDash) {
                ctx.setLineDash([])
            }

            ctx.globalAlpha = 0.16
            ctx.fillRect(cursorX - 11, 4, 22, 14)
            ctx.fillRect(drawWidth - 74, cursorY - 8, 66, 16)
            ctx.globalAlpha = 1.0
            ctx.beginPath()
            ctx.arc(cursorX, cursorY, selectedCursor === index ? 5.2 : 4.0, 0, Math.PI * 2)
            ctx.stroke()
            ctx.beginPath()
            ctx.arc(cursorX, cursorY, 1.6, 0, Math.PI * 2)
            ctx.fill()

            drawBadge(
                ctx,
                labels[index] + " " + formatTimeMetric(cursorAbsoluteTimeMs(timeValues[index])),
                cursorX - 26,
                focusTop + 6 + (index * 18),
                "#0F1822",
                colors[index],
                colors[index],
                drawWidth,
                drawHeight
            )
            drawBadge(
                ctx,
                formatVoltageMetric(cursorAbsoluteVoltage(voltageValues[index])),
                drawWidth - 108,
                cursorY - 8,
                "#0F1822",
                colors[index],
                colors[index],
                drawWidth,
                drawHeight
            )
        }

        var leftX = Math.min(cursorXs[0], cursorXs[1])
        var rightX = Math.max(cursorXs[0], cursorXs[1])
        ctx.fillStyle = "#0E1720"
        ctx.strokeStyle = "#2B4865"
        ctx.lineWidth = 1
        ctx.globalAlpha = 0.82
        ctx.fillRect(leftX, deltaTop, Math.max(10, rightX - leftX), 10)
        ctx.globalAlpha = 1.0
        ctx.strokeRect(leftX + 0.5, deltaTop + 0.5, Math.max(9, rightX - leftX) - 1, 9)
        ctx.fillStyle = "#D7E6F5"
        ctx.fillText("dT " + formatTimeMetric(cursorDeltaTimeMs()) + "   dV " + formatVoltageMetric(cursorDeltaVoltage()), Math.max(10, leftX), deltaTop - 4)
        ctx.restore()
    }

    onTimebaseIndexChanged: rebuildTraceCaches()
    onVoltsDivIndexChanged: requestRender()
    onTriggerLevelChanged: requestRender()
    onTriggerModeChanged: requestRender()
    onTriggerSourceChanged: requestRender()
    onViewModeChanged: requestRender()
    onPersistenceIndexChanged: refreshHistoryLimit()
    onIntensityIndexChanged: requestRender()
    onCoupling1Changed: rebuildTraceCaches()
    onCoupling2Changed: rebuildTraceCaches()
    onCoupling3Changed: rebuildTraceCaches()
    onCoupling4Changed: rebuildTraceCaches()
    onVisible1Changed: requestRender()
    onVisible2Changed: requestRender()
    onVisible3Changed: requestRender()
    onVisible4Changed: requestRender()
    onFocusChannelChanged: requestRender()
    onHasFrameChanged: requestRender()
    onShowEnvelopeChanged: rebuildTraceCaches()
    onShowCursorsChanged: requestRender()
    onSelectedCursorChanged: requestRender()
    onCursorTimeAChanged: requestRender()
    onCursorTimeBChanged: requestRender()
    onCursorVoltAChanged: requestRender()
    onCursorVoltBChanged: requestRender()
    onEffectChanged: syncNotifyBroadcast()
    onHasEffectChanged: syncNotifyBroadcast()

    Component.onCompleted: {
        syncNotifyBroadcast()
    }

    Component.onDestruction: {
        disableNotifyBroadcast()
    }

    Connections {
        target: scopeFrames
        onFrameChanged: {
            if (arguments[0] !== scopeView.effect || scopeView.freeze) {
                return
            }

            // arguments[1] is already a JS array (QVariantList from Python),
            // no JSON.parse needed.
            var frames = arguments[1]
            if (!frames || frames.length < 4) {
                scopeView.resetTraceState()
                return
            }

            scopeView.setFrames(frames)
        }
    }

    Rectangle {
        anchors.fill: parent
        radius: 8
        gradient: Gradient {
            GradientStop { position: 0.0; color: "#0A1016" }
            GradientStop { position: 0.55; color: "#090D12" }
            GradientStop { position: 1.0; color: "#06090E" }
        }
        border.color: "#17212E"
        border.width: 2
    }

    Rectangle {
        x: 24
        y: 20
        width: parent.width - 48
        height: 84
        radius: 12
        gradient: Gradient {
            GradientStop { position: 0.0; color: "#121B27" }
            GradientStop { position: 1.0; color: "#0F1620" }
        }
        border.color: "#223140"
        border.width: 1

        Text {
            x: 24
            y: 12
            text: "POLY SCOPE"
            color: "white"
            font.family: mainFont.name
            font.pixelSize: 31
            font.capitalization: Font.AllUppercase
        }

        Text {
            x: 26
            y: 47
            text: scopeView.isXYView ? "4 in / 4 thru vector scope with persistence" : "4 in / 4 thru triggered oscilloscope"
            color: "#7C92AE"
            font.family: mainFont.name
            font.pixelSize: 18
            font.capitalization: Font.AllUppercase
        }

        Rectangle {
            x: parent.width - 244
            y: 14
            width: 214
            height: 24
            radius: 12
            color: "#13212E"
            border.color: "#2B4865"
            border.width: 1

            Text {
                anchors.centerIn: parent
                text: scopeView.viewModeLabels[scopeView.viewMode]
                color: "#90E7D0"
                font.family: mainFont.name
                font.pixelSize: 15
                font.capitalization: Font.AllUppercase
            }
        }

        Text {
            x: parent.width - 272
            y: 46
            width: 242
            horizontalAlignment: Text.AlignRight
            text: scopeView.timebaseLabels[scopeView.timebaseIndex] + "  /  " + scopeView.voltsDivLabels[scopeView.voltsDivIndex]
            color: "#D7E6F5"
            font.family: mainFont.name
            font.pixelSize: 17
            font.capitalization: Font.AllUppercase
        }
    }

    Rectangle {
        x: 24
        y: 116
        width: parent.width - 48
        height: 76
        radius: 12
        color: "#101723"
        border.color: "#223140"
        border.width: 1

        Row {
            x: 16
            y: 15
            spacing: 10

            Rectangle {
                width: 126
                height: 46
                radius: 8
                color: scopeView.freeze ? "#24374C" : "#13212E"
                border.color: scopeView.freeze ? "#FFD166" : "#284055"
                border.width: 1

                Text {
                    anchors.centerIn: parent
                    text: scopeView.freeze ? "FROZEN" : "RUNNING"
                    color: scopeView.freeze ? "#FFD166" : "#D7E6F5"
                    font.family: mainFont.name
                    font.pixelSize: 18
                    font.capitalization: Font.AllUppercase
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: scopeView.toggleFreeze()
                }
            }

            Rectangle {
                width: 110
                height: 46
                radius: 8
                color: "#13212E"
                border.color: "#284055"
                border.width: 1

                Text {
                    anchors.centerIn: parent
                    text: "CLEAR"
                    color: "#D7E6F5"
                    font.family: mainFont.name
                    font.pixelSize: 18
                    font.capitalization: Font.AllUppercase
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: scopeView.clearTraces()
                }
            }

            Rectangle {
                width: 90
                height: 46
                radius: 8
                color: "#13212E"
                border.color: "#284055"
                border.width: 1

                Text {
                    anchors.centerIn: parent
                    text: "TIME -"
                    color: "#D7E6F5"
                    font.family: mainFont.name
                    font.pixelSize: 17
                    font.capitalization: Font.AllUppercase
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: scopeView.stepIntControl("timebase", scopeView.timebaseIndex, 0, 7, -1)
                }
            }

            Rectangle {
                width: 146
                height: 46
                radius: 8
                color: "#0F1620"
                border.color: "#243241"
                border.width: 1

                Text {
                    anchors.centerIn: parent
                    text: scopeView.timebaseLabels[scopeView.timebaseIndex]
                    color: "#90E7D0"
                    font.family: mainFont.name
                    font.pixelSize: 19
                }
            }

            Rectangle {
                width: 90
                height: 46
                radius: 8
                color: "#13212E"
                border.color: "#284055"
                border.width: 1

                Text {
                    anchors.centerIn: parent
                    text: "TIME +"
                    color: "#D7E6F5"
                    font.family: mainFont.name
                    font.pixelSize: 17
                    font.capitalization: Font.AllUppercase
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: scopeView.stepIntControl("timebase", scopeView.timebaseIndex, 0, 7, 1)
                }
            }

            Rectangle {
                width: 90
                height: 46
                radius: 8
                color: "#13212E"
                border.color: "#284055"
                border.width: 1

                Text {
                    anchors.centerIn: parent
                    text: "SCALE -"
                    color: "#D7E6F5"
                    font.family: mainFont.name
                    font.pixelSize: 17
                    font.capitalization: Font.AllUppercase
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: scopeView.stepIntControl("volts_div", scopeView.voltsDivIndex, 0, 4, -1)
                }
            }

            Rectangle {
                width: 138
                height: 46
                radius: 8
                color: "#0F1620"
                border.color: "#243241"
                border.width: 1

                Text {
                    anchors.centerIn: parent
                    text: scopeView.voltsDivLabels[scopeView.voltsDivIndex]
                    color: "#90E7D0"
                    font.family: mainFont.name
                    font.pixelSize: 19
                }
            }

            Rectangle {
                width: 90
                height: 46
                radius: 8
                color: "#13212E"
                border.color: "#284055"
                border.width: 1

                Text {
                    anchors.centerIn: parent
                    text: "SCALE +"
                    color: "#D7E6F5"
                    font.family: mainFont.name
                    font.pixelSize: 17
                    font.capitalization: Font.AllUppercase
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: scopeView.stepIntControl("volts_div", scopeView.voltsDivIndex, 0, 4, 1)
                }
            }
        }
    }

    Rectangle {
        x: 24
        y: 204
        width: parent.width - 48
        height: 88
        radius: 12
        color: "#101723"
        border.color: "#223140"
        border.width: 1

        Row {
            x: 16
            y: 10
            spacing: 12

            Rectangle {
                width: 248
                height: 30
                radius: 8
                color: "#0F1620"
                border.color: "#243241"
                border.width: 1

                Text {
                    x: 12
                    y: 6
                    text: "TRIGGER MODE"
                    color: "#7C92AE"
                    font.family: mainFont.name
                    font.pixelSize: 14
                    font.capitalization: Font.AllUppercase
                }

                Row {
                    x: 110
                    y: 4
                    spacing: 8

                    Repeater {
                        model: scopeView.triggerModeLabels

                        delegate: Rectangle {
                            width: 40
                            height: 22
                            radius: 6
                            color: index === scopeView.triggerMode ? "#24374C" : "#13212E"
                            border.color: index === scopeView.triggerMode ? "#FFD166" : "#284055"
                            border.width: 1

                            Text {
                                anchors.centerIn: parent
                                text: modelData
                                color: index === scopeView.triggerMode ? "#FFD166" : "#D7E6F5"
                                font.family: mainFont.name
                                font.pixelSize: 12
                                font.capitalization: Font.AllUppercase
                            }

                            MouseArea {
                                anchors.fill: parent
                                onClicked: scopeView.setIntControl("trigger_mode", index)
                            }
                        }
                    }
                }
            }

            Rectangle {
                width: 256
                height: 30
                radius: 8
                color: "#0F1620"
                border.color: "#243241"
                border.width: 1

                Text {
                    x: 12
                    y: 6
                    text: "TRIGGER SRC"
                    color: "#7C92AE"
                    font.family: mainFont.name
                    font.pixelSize: 14
                    font.capitalization: Font.AllUppercase
                }

                Row {
                    x: 106
                    y: 4
                    spacing: 8

                    Repeater {
                        model: 4

                        delegate: Rectangle {
                            width: 34
                            height: 22
                            radius: 6
                            color: (index + 1) === scopeView.triggerSource ? "#24374C" : "#13212E"
                            border.color: (index + 1) === scopeView.triggerSource ? scopeView.channelColors[index] : "#284055"
                            border.width: 1

                            Text {
                                anchors.centerIn: parent
                                text: index + 1
                                color: (index + 1) === scopeView.triggerSource ? scopeView.channelColors[index] : "#D7E6F5"
                                font.family: mainFont.name
                                font.pixelSize: 12
                            }

                            MouseArea {
                                anchors.fill: parent
                                onClicked: scopeView.setIntControl("trigger_source", index + 1)
                            }
                        }
                    }
                }
            }

            Rectangle {
                width: 420
                height: 30
                radius: 8
                color: "#0F1620"
                border.color: "#243241"
                border.width: 1

                Text {
                    x: 12
                    y: 6
                    text: "VIEW"
                    color: "#7C92AE"
                    font.family: mainFont.name
                    font.pixelSize: 14
                    font.capitalization: Font.AllUppercase
                }

                Row {
                    x: 60
                    y: 4
                    spacing: 8

                    Repeater {
                        model: scopeView.viewModeLabels

                        delegate: Rectangle {
                            width: 84
                            height: 22
                            radius: 6
                            color: index === scopeView.viewMode ? "#24374C" : "#13212E"
                            border.color: index === scopeView.viewMode ? "#90E7D0" : "#284055"
                            border.width: 1

                            Text {
                                anchors.centerIn: parent
                                text: modelData
                                color: index === scopeView.viewMode ? "#90E7D0" : "#D7E6F5"
                                font.family: mainFont.name
                                font.pixelSize: 12
                                font.capitalization: Font.AllUppercase
                            }

                            MouseArea {
                                anchors.fill: parent
                                onClicked: scopeView.setIntControl("view_mode", index)
                            }
                        }
                    }
                }
            }
        }

        Row {
            x: 16
            y: 48
            spacing: 12

            Rectangle {
                width: 250
                height: 28
                radius: 8
                color: "#0F1620"
                border.color: "#243241"
                border.width: 1

                Text {
                    x: 12
                    y: 6
                    text: "PERSISTENCE"
                    color: "#7C92AE"
                    font.family: mainFont.name
                    font.pixelSize: 13
                    font.capitalization: Font.AllUppercase
                }

                Row {
                    x: 112
                    y: 4
                    spacing: 6

                    Repeater {
                        model: scopeView.persistenceLabels

                        delegate: Rectangle {
                            width: 22
                            height: 20
                            radius: 5
                            color: index === scopeView.persistenceIndex ? "#24374C" : "#13212E"
                            border.color: index === scopeView.persistenceIndex ? "#90E7D0" : "#284055"
                            border.width: 1

                            Text {
                                anchors.centerIn: parent
                                text: index
                                color: index === scopeView.persistenceIndex ? "#90E7D0" : "#D7E6F5"
                                font.family: mainFont.name
                                font.pixelSize: 11
                            }

                            MouseArea {
                                anchors.fill: parent
                                onClicked: scopeView.setIntControl("persistence", index)
                            }
                        }
                    }
                }
            }

            Rectangle {
                width: 232
                height: 28
                radius: 8
                color: "#0F1620"
                border.color: "#243241"
                border.width: 1

                Text {
                    x: 12
                    y: 6
                    text: "INTENSITY"
                    color: "#7C92AE"
                    font.family: mainFont.name
                    font.pixelSize: 13
                    font.capitalization: Font.AllUppercase
                }

                Row {
                    x: 96
                    y: 4
                    spacing: 6

                    Repeater {
                        model: scopeView.intensityLabels

                        delegate: Rectangle {
                            width: 22
                            height: 20
                            radius: 5
                            color: index === scopeView.intensityIndex ? "#24374C" : "#13212E"
                            border.color: index === scopeView.intensityIndex ? "#FFD166" : "#284055"
                            border.width: 1

                            Text {
                                anchors.centerIn: parent
                                text: index
                                color: index === scopeView.intensityIndex ? "#FFD166" : "#D7E6F5"
                                font.family: mainFont.name
                                font.pixelSize: 11
                            }

                            MouseArea {
                                anchors.fill: parent
                                onClicked: scopeView.setIntControl("intensity", index)
                            }
                        }
                    }
                }
            }

            Rectangle {
                width: 478
                height: 28
                radius: 8
                color: "#0F1620"
                border.color: "#243241"
                border.width: 1

                Text {
                    x: 12
                    y: 6
                    text: "TRIGGER LEVEL " + scopeView.triggerLevel.toFixed(2)
                    color: "#7C92AE"
                    font.family: mainFont.name
                    font.pixelSize: 13
                    font.capitalization: Font.AllUppercase
                }

                Slider {
                    x: 164
                    y: 2
                    width: 302
                    height: 24
                    from: -1.0
                    to: 1.0
                    value: scopeView.triggerLevel
                    onMoved: knobs.ui_knob_change(effect, "trigger_level", value)
                }
            }
        }
    }

    Rectangle {
        x: 24
        y: 304
        width: parent.width - 48
        height: parent.height - 328
        radius: 12
        gradient: Gradient {
            GradientStop { position: 0.0; color: "#0D141D" }
            GradientStop { position: 1.0; color: "#0B1118" }
        }
        border.color: "#223140"
        border.width: 1

        Canvas {
            id: chart
            x: 16
            y: 16
            width: parent.width - 320
            height: parent.height - 32

            onPaint: {
                var ctx = getContext("2d")
                var drawWidth = width
                var drawHeight = height
                ctx.clearRect(0, 0, drawWidth, drawHeight)

                var gradient = ctx.createLinearGradient(0, 0, 0, drawHeight)
                gradient.addColorStop(0.0, "#0E1620")
                gradient.addColorStop(1.0, "#0B1016")
                ctx.fillStyle = gradient
                ctx.fillRect(0, 0, drawWidth, drawHeight)

                if (!scopeView.hasFrame) {
                    ctx.fillStyle = "#7C92AE"
                    ctx.font = "26px " + mainFont.name
                    ctx.fillText("Waiting for notify stream", drawWidth / 2 - 150, drawHeight / 2 - 8)
                    ctx.font = "18px " + mainFont.name
                    ctx.fillText("Patch a signal into any channel to populate the frame buffer.", drawWidth / 2 - 235, drawHeight / 2 + 24)
                    return
                }

                var historyFrames = scopeView.processedHistory

                if (scopeView.isXYView) {
                    var xChannel = scopeView.xyStartChannel
                    var yChannel = scopeView.xyStartChannel + 1
                    if (!scopeView.channelVisible(xChannel) || !scopeView.channelVisible(yChannel)) {
                        ctx.fillStyle = "#7C92AE"
                        ctx.font = "24px " + mainFont.name
                        ctx.fillText("Enable both channels for XY view", drawWidth / 2 - 165, drawHeight / 2 - 4)
                        ctx.font = "18px " + mainFont.name
                        ctx.fillText("Current pair: " + scopeView.channelLabels[xChannel] + " / " + scopeView.channelLabels[yChannel], drawWidth / 2 - 112, drawHeight / 2 + 26)
                        return
                    }

                    var plotSize = Math.min(drawWidth - 36, drawHeight - 36)
                    var plotLeft = (drawWidth - plotSize) / 2
                    var plotTop = (drawHeight - plotSize) / 2
                    scopeView.drawXYGrid(ctx, plotLeft, plotTop, plotSize, plotSize)

                    for (var historyIndex = historyFrames.length - 1; historyIndex >= 0; --historyIndex) {
                        var alpha = scopeView.traceIntensity * Math.pow(0.56, historyIndex)
                        var frame = historyFrames[historyIndex]
                        var historyX = frame[xChannel]
                        var historyY = frame[yChannel]
                        scopeView.drawXYTrace(
                            ctx,
                            historyX,
                            historyY,
                            plotLeft,
                            plotTop,
                            plotSize,
                            plotSize,
                            scopeView.channelColors[xChannel],
                            alpha
                        )
                    }

                    ctx.fillStyle = scopeView.channelColors[xChannel]
                    ctx.font = "20px " + mainFont.name
                    ctx.fillText(scopeView.channelLabels[xChannel] + " -> X", 18, 24)
                    ctx.fillStyle = scopeView.channelColors[yChannel]
                    ctx.fillText(scopeView.channelLabels[yChannel] + " -> Y", 18, 48)
                    ctx.fillStyle = "#7C92AE"
                    ctx.font = "15px " + mainFont.name
                    ctx.fillText("visible window " + scopeView.visibleWindowMs().toFixed(1) + " ms", drawWidth - 188, 24)
                    ctx.fillText("persistence " + scopeView.persistenceLabels[scopeView.persistenceIndex], drawWidth - 182, 48)
                    ctx.fillText("corr " + scopeView.estimateCorrelation(scopeView.currentTrace(xChannel), scopeView.currentTrace(yChannel)).toFixed(2), drawWidth - 116, 72)
                } else if (scopeView.viewMode === 1) {
                    scopeView.drawScopeGrid(ctx, 0, drawHeight, drawWidth)
                    if (scopeView.channelVisible(scopeView.triggerSource - 1)) {
                        scopeView.drawTriggerGuide(ctx, 0, drawHeight, scopeView.channelColors[Math.max(0, scopeView.triggerSource - 1)], drawWidth)
                    }

                    if (scopeView.showEnvelope) {
                        for (var envelopeChannel = 0; envelopeChannel < 4; ++envelopeChannel) {
                            if (!scopeView.channelVisible(envelopeChannel)) {
                                continue
                            }
                            scopeView.drawScopeEnvelope(
                                ctx,
                                scopeView.historyEnvelope(envelopeChannel),
                                0,
                                drawHeight,
                                scopeView.channelColors[envelopeChannel],
                                scopeView.traceIntensity,
                                drawWidth
                            )
                        }
                    }

                    for (historyIndex = historyFrames.length - 1; historyIndex >= 0; --historyIndex) {
                        alpha = scopeView.traceIntensity * Math.pow(0.56, historyIndex)
                        frame = historyFrames[historyIndex]
                        for (var overlayChannel = 0; overlayChannel < 4; ++overlayChannel) {
                            if (!scopeView.channelVisible(overlayChannel)) {
                                continue
                            }
                            scopeView.drawScopeTrace(
                                ctx,
                                frame[overlayChannel],
                                0,
                                drawHeight,
                                scopeView.channelColors[overlayChannel],
                                alpha,
                                drawWidth
                            )
                        }
                    }

                    var legendY = 24
                    for (overlayChannel = 0; overlayChannel < 4; ++overlayChannel) {
                        if (!scopeView.channelVisible(overlayChannel)) {
                            continue
                        }
                        var overlayStats = scopeView.channelStats(overlayChannel)
                        ctx.fillStyle = scopeView.channelColors[overlayChannel]
                        ctx.font = "15px " + mainFont.name
                        ctx.fillText(
                            scopeView.channelLabels[overlayChannel] + "  " + scopeView.couplingLabel(overlayChannel) + "  pp " + scopeView.formatMetric(overlayStats.pp) + "  rms " + scopeView.formatMetric(overlayStats.rms),
                            16,
                            legendY
                        )
                        scopeView.drawHoldMarkers(ctx, 0, drawHeight, scopeView.holdMarkers[overlayChannel], scopeView.channelColors[overlayChannel], drawWidth, overlayChannel * 16)
                        legendY += 22
                    }
                    scopeView.drawTimeRuler(ctx, drawWidth, drawHeight)
                    scopeView.drawMeasurementCursors(ctx, 0, drawHeight, drawWidth, drawHeight)
                } else {
                    var rowHeight = drawHeight / 4
                    for (var channel = 0; channel < 4; ++channel) {
                        var top = rowHeight * channel
                        var rowGradient = ctx.createLinearGradient(0, top, drawWidth, top + rowHeight)
                        rowGradient.addColorStop(0.0, channel % 2 === 0 ? "#0D141C" : "#0F1721")
                        rowGradient.addColorStop(1.0, channel % 2 === 0 ? "#0C131B" : "#0D151F")
                        ctx.fillStyle = rowGradient
                        ctx.fillRect(0, top, drawWidth, rowHeight)
                        scopeView.drawScopeGrid(ctx, top, rowHeight, drawWidth)

                        ctx.fillStyle = scopeView.channelVisible(channel) ? scopeView.channelColors[channel] : scopeView.dimChannelColors[channel]
                        ctx.fillRect(0, top, 4, rowHeight)

                        if (scopeView.channelVisible(channel)) {
                            if ((channel + 1) === scopeView.triggerSource) {
                                scopeView.drawTriggerGuide(ctx, top, rowHeight, scopeView.channelColors[channel], drawWidth)
                            }

                            if (scopeView.showEnvelope) {
                                scopeView.drawScopeEnvelope(
                                    ctx,
                                    scopeView.historyEnvelope(channel),
                                    top,
                                    rowHeight,
                                    scopeView.channelColors[channel],
                                    scopeView.traceIntensity,
                                    drawWidth
                                )
                            }

                            for (historyIndex = historyFrames.length - 1; historyIndex >= 0; --historyIndex) {
                                alpha = scopeView.traceIntensity * Math.pow(0.56, historyIndex)
                                frame = historyFrames[historyIndex]
                                scopeView.drawScopeTrace(
                                    ctx,
                                    frame[channel],
                                    top,
                                    rowHeight,
                                    scopeView.channelColors[channel],
                                    alpha,
                                    drawWidth
                                )
                            }
                            scopeView.drawHoldMarkers(ctx, top, rowHeight, scopeView.holdMarkers[channel], scopeView.channelColors[channel], drawWidth, 0)
                        } else {
                            ctx.fillStyle = "#546678"
                            ctx.font = "16px " + mainFont.name
                            ctx.fillText("hidden", drawWidth - 64, top + 24)
                        }

                        var currentStats = scopeView.channelStats(channel)
                        ctx.fillStyle = scopeView.channelVisible(channel) ? scopeView.channelColors[channel] : scopeView.dimChannelColors[channel]
                        ctx.font = "19px " + mainFont.name
                        ctx.fillText(scopeView.channelLabels[channel], 16, top + 22)
                        ctx.fillStyle = "#90A6BE"
                        ctx.font = "12px " + mainFont.name
                        ctx.fillText(scopeView.couplingLabel(channel), 18, top + 40)
                        ctx.fillText(scopeView.channelVisible(channel) ? "ON" : "OFF", 56, top + 40)
                        ctx.fillStyle = "#D7E6F5"
                        ctx.font = "14px " + mainFont.name
                        ctx.fillText("pp " + scopeView.formatMetric(currentStats.pp), drawWidth - 98, top + 22)
                        ctx.fillText("rms " + scopeView.formatMetric(currentStats.rms), drawWidth - 108, top + 40)
                    }
                    scopeView.drawTimeRuler(ctx, drawWidth, drawHeight)
                    scopeView.drawMeasurementCursors(ctx, rowHeight * scopeView.focusChannel, rowHeight, drawWidth, drawHeight)
                }
            }
        }

        MouseArea {
            anchors.fill: chart
            enabled: scopeView.showCursors && !scopeView.isXYView
            preventStealing: true
            onPressed: scopeView.updateSelectedCursorFromPlot(mouse.x, mouse.y, chart.width, chart.height)
            onPositionChanged: {
                if (pressed) {
                    scopeView.updateSelectedCursorFromPlot(mouse.x, mouse.y, chart.width, chart.height)
                }
            }
        }

        Column {
            x: parent.width - 286
            y: 12
            spacing: 6

            Rectangle {
                width: 270
                height: 64
                radius: 10
                color: "#111A25"
                border.color: scopeView.channelColors[scopeView.focusChannel]
                border.width: 1

                property var focusTrace: scopeView.currentTrace(scopeView.focusChannel)
                property var focusStats: scopeView.channelStats(scopeView.focusChannel)
                property var focusHold: scopeView.holdMarkers[scopeView.focusChannel]

                Text {
                    x: 12
                    y: 7
                    text: "FOCUS " + scopeView.channelLabels[scopeView.focusChannel]
                    color: scopeView.channelColors[scopeView.focusChannel]
                    font.family: mainFont.name
                    font.pixelSize: 16
                    font.capitalization: Font.AllUppercase
                }

                Text {
                    x: 12
                    y: 24
                    text: "pp " + scopeView.formatMetric(parent.focusStats.pp) + "   rms " + scopeView.formatMetric(parent.focusStats.rms) + "   " + scopeView.formatFrequency(parent.focusStats.frequency)
                    color: "#D7E6F5"
                    font.family: mainFont.name
                    font.pixelSize: 11
                    font.capitalization: Font.AllUppercase
                }

                Text {
                    x: 12
                    y: 38
                    text: scopeView.showCursors ?
                              "A " + scopeView.formatTimeMetric(scopeView.cursorAbsoluteTimeMs(scopeView.cursorTimeA)) + " " + scopeView.formatVoltageMetric(scopeView.cursorAbsoluteVoltage(scopeView.cursorVoltA)) + "   B " + scopeView.formatTimeMetric(scopeView.cursorAbsoluteTimeMs(scopeView.cursorTimeB)) + " " + scopeView.formatVoltageMetric(scopeView.cursorAbsoluteVoltage(scopeView.cursorVoltB)) :
                              "mean " + scopeView.formatMetric(parent.focusStats.mean) + "   min " + scopeView.formatMetric(parent.focusStats.minimum) + "   max " + scopeView.formatMetric(parent.focusStats.maximum)
                    color: "#7C92AE"
                    font.family: mainFont.name
                    font.pixelSize: 9
                    font.capitalization: Font.AllUppercase
                }

                Text {
                    x: 12
                    y: 51
                    text: scopeView.showCursors ?
                              "dT " + scopeView.formatTimeMetric(scopeView.cursorDeltaTimeMs()) + "   dV " + scopeView.formatVoltageMetric(scopeView.cursorDeltaVoltage()) + "   1/dT " + scopeView.formatFrequency(scopeView.cursorFrequencyHz()) :
                              (parent.focusHold ? "hold " + scopeView.formatMetric(parent.focusHold.minimum) + " .. " + scopeView.formatMetric(parent.focusHold.maximum) : "hold --")
                    color: "#7C92AE"
                    font.family: mainFont.name
                    font.pixelSize: 9
                    font.capitalization: Font.AllUppercase
                }
            }

            Rectangle {
                width: 270
                height: 32
                radius: 10
                color: "#111A25"
                border.color: "#243241"
                border.width: 1

                Row {
                    x: 10
                    y: 5
                    spacing: 6

                    Rectangle {
                        width: 74
                        height: 22
                        radius: 6
                        color: "#1B2A39"
                        border.color: "#90E7D0"
                        border.width: 1

                        Text {
                            anchors.centerIn: parent
                            text: "AUTOSET"
                            color: "#90E7D0"
                            font.family: mainFont.name
                            font.pixelSize: 11
                            font.capitalization: Font.AllUppercase
                        }

                        MouseArea {
                            anchors.fill: parent
                            onClicked: scopeView.autosetScope()
                        }
                    }

                    Rectangle {
                        width: 44
                        height: 22
                        radius: 6
                        color: scopeView.showEnvelope ? "#24374C" : "#13212E"
                        border.color: scopeView.showEnvelope ? "#FFD166" : "#284055"
                        border.width: 1

                        Text {
                            anchors.centerIn: parent
                            text: "HOLD"
                            color: scopeView.showEnvelope ? "#FFD166" : "#D7E6F5"
                            font.family: mainFont.name
                            font.pixelSize: 10
                            font.capitalization: Font.AllUppercase
                        }

                        MouseArea {
                            anchors.fill: parent
                            onClicked: scopeView.showEnvelope = !scopeView.showEnvelope
                        }
                    }

                    Rectangle {
                        width: 62
                        height: 22
                        radius: 6
                        color: scopeView.showCursors ? "#24374C" : "#13212E"
                        border.color: scopeView.showCursors ? "#90E7D0" : "#284055"
                        border.width: 1

                        Text {
                            anchors.centerIn: parent
                            text: "CURSORS"
                            color: scopeView.showCursors ? "#90E7D0" : "#D7E6F5"
                            font.family: mainFont.name
                            font.pixelSize: 10
                            font.capitalization: Font.AllUppercase
                        }

                        MouseArea {
                            anchors.fill: parent
                            onClicked: scopeView.showCursors = !scopeView.showCursors
                        }
                    }

                    Repeater {
                        model: 2

                        delegate: Rectangle {
                            width: 22
                            height: 22
                            radius: 6
                            color: scopeView.selectedCursor === index ? "#24374C" : "#13212E"
                            border.color: scopeView.selectedCursor === index ? (index === 0 ? "#90E7D0" : "#FFD166") : "#284055"
                            border.width: 1
                            opacity: scopeView.showCursors ? 1.0 : 0.35

                            Text {
                                anchors.centerIn: parent
                                text: index === 0 ? "A" : "B"
                                color: scopeView.selectedCursor === index ? (index === 0 ? "#90E7D0" : "#FFD166") : "#D7E6F5"
                                font.family: mainFont.name
                                font.pixelSize: 10
                                font.capitalization: Font.AllUppercase
                            }

                            MouseArea {
                                anchors.fill: parent
                                enabled: scopeView.showCursors
                                onClicked: scopeView.selectedCursor = index
                            }
                        }
                    }
                }
            }

            Repeater {
                model: 4

                delegate: Rectangle {
                    id: channelCard
                    width: 270
                    height: 34
                    radius: 10
                    color: scopeView.focusChannel === index ? "#162231" : "#111A25"
                    border.color: scopeView.focusChannel === index ? scopeView.channelColors[index] : "#243241"
                    border.width: 1

                    property int channelIndex: index
                    property var stats: scopeView.channelStats(channelIndex)

                    Text {
                        x: 12
                        y: 4
                        text: scopeView.channelLabels[channelCard.channelIndex]
                        color: scopeView.channelVisible(channelCard.channelIndex) ? scopeView.channelColors[channelCard.channelIndex] : scopeView.dimChannelColors[channelCard.channelIndex]
                        font.family: mainFont.name
                        font.pixelSize: 15
                        font.capitalization: Font.AllUppercase
                    }

                    Text {
                        x: 208
                        y: 6
                        text: "THRU " + (channelCard.channelIndex + 1)
                        color: "#6D8195"
                        font.family: mainFont.name
                        font.pixelSize: 9
                        font.capitalization: Font.AllUppercase
                    }

                    Rectangle {
                        x: 58
                        y: 4
                        width: 34
                        height: 16
                        radius: 5
                        color: scopeView.channelVisible(channelCard.channelIndex) ? "#1D3028" : "#2B1A1A"
                        border.color: scopeView.channelVisible(channelCard.channelIndex) ? scopeView.channelColors[channelCard.channelIndex] : "#6A4040"
                        border.width: 1

                        Text {
                            anchors.centerIn: parent
                            text: scopeView.channelVisible(channelCard.channelIndex) ? "ON" : "OFF"
                            color: scopeView.channelVisible(channelCard.channelIndex) ? scopeView.channelColors[channelCard.channelIndex] : "#FF8A8A"
                            font.family: mainFont.name
                            font.pixelSize: 9
                            font.capitalization: Font.AllUppercase
                        }

                        MouseArea {
                            anchors.fill: parent
                            onClicked: scopeView.toggleChannelVisible(channelCard.channelIndex)
                        }
                    }

                    Row {
                        x: 98
                        y: 4
                        spacing: 4

                        Repeater {
                            model: scopeView.couplingLabels

                            delegate: Rectangle {
                                id: couplingToggle
                                width: 24
                                height: 16
                                radius: 5
                                property int channelIndex: channelCard.channelIndex
                                color: index === scopeView.couplingMode(channelIndex) ? "#24374C" : "#13212E"
                                border.color: index === scopeView.couplingMode(channelIndex) ? scopeView.channelColors[channelIndex] : "#284055"
                                border.width: 1

                                Text {
                                    anchors.centerIn: parent
                                    text: modelData
                                    color: index === scopeView.couplingMode(couplingToggle.channelIndex) ? scopeView.channelColors[couplingToggle.channelIndex] : "#D7E6F5"
                                    font.family: mainFont.name
                                    font.pixelSize: 8
                                    font.capitalization: Font.AllUppercase
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: scopeView.setIntControl(scopeView.couplingName(couplingToggle.channelIndex), index)
                                }
                            }
                        }
                    }

                    Text {
                        x: 12
                        y: 20
                        text: "pp " + scopeView.formatMetric(channelCard.stats.pp) + "   rms " + scopeView.formatMetric(channelCard.stats.rms) + "   " + scopeView.formatFrequency(channelCard.stats.frequency)
                        color: "#9CB2C8"
                        font.family: mainFont.name
                        font.pixelSize: 9
                        font.capitalization: Font.AllUppercase
                    }

                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.LeftButton
                        onClicked: scopeView.focusChannel = channelCard.channelIndex
                    }
                }
            }
        }
    }
}
