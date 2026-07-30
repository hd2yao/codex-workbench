import ApplicationServices
import Foundation

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard
        AXUIElementCopyAttributeValue(element, name as CFString, &value)
            == .success
    else {
        return nil
    }
    return value
}

func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
    attribute(element, name) as? String
}

func pointAttribute(_ element: AXUIElement, _ name: String) -> CGPoint? {
    guard let value = attribute(element, name) else { return nil }
    let axValue = unsafeBitCast(value, to: AXValue.self)
    guard AXValueGetType(axValue) == .cgPoint else { return nil }
    var point = CGPoint.zero
    guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
    return point
}

func sizeAttribute(_ element: AXUIElement, _ name: String) -> CGSize? {
    guard let value = attribute(element, name) else { return nil }
    let axValue = unsafeBitCast(value, to: AXValue.self)
    guard AXValueGetType(axValue) == .cgSize else { return nil }
    var size = CGSize.zero
    guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
    return size
}

guard
    CommandLine.arguments.count == 2,
    let processIdentifier = Int32(CommandLine.arguments[1]),
    processIdentifier > 0
else {
    fputs("usage: scroll-content.swift <pid>\n", stderr)
    exit(2)
}

let application = AXUIElementCreateApplication(processIdentifier)
var stack = [application]
var visited = 0
var didScroll = false

while let element = stack.popLast(), visited < 20_000 {
    visited += 1
    if
        stringAttribute(element, kAXRoleAttribute) == kAXScrollBarRole,
        stringAttribute(element, kAXOrientationAttribute)
            == kAXVerticalOrientationValue,
        let position = pointAttribute(element, kAXPositionAttribute),
        let size = sizeAttribute(element, kAXSizeAttribute),
        position.x > 400,
        size.height > 300
    {
        let result = AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            NSNumber(value: 1.0)
        )
        if result == .success {
            didScroll = true
        }
    }
    if let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
        stack.append(contentsOf: children)
    }
}

guard didScroll else {
    fputs("FAIL: content vertical scroll bar not found\n", stderr)
    exit(1)
}
