import CodexWorkbenchCore

func runTokenCountFormatterTests(_ runner: inout TestRunner) {
    let cases: [(Int, String)] = [
        (0, "0"),
        (9_999, "9,999"),
        (10_000, "1万"),
        (39_000, "3.9万"),
        (99_999_999, "9999.9999万"),
        (100_000_000, "1亿"),
        (234_593_012, "2.35亿"),
        (4_849_800_000, "48.5亿"),
        (1_020_000_000_000, "1.02万亿"),
        (-234_593_012, "-2.35亿"),
    ]

    for (value, expected) in cases {
        runner.expect(
            TokenCountFormatter.chinese(value) == expected,
            "\(value) should format as \(expected)"
        )
    }

    runner.expect(
        TokenCountFormatter.exact(234_593_012) == "234,593,012",
        "Exact values should use decimal grouping"
    )
    runner.expect(
        TokenCountFormatter.accessibility(234_593_012)
            == "234,593,012 Tokens（约 2.35亿）",
        "Accessibility values should expose exact and Chinese quantities"
    )

    let minimum = TokenCountFormatter.chinese(Int.min)
    runner.expect(minimum.hasPrefix("-"), "Int.min should preserve its sign without overflowing")
    runner.expect(minimum.hasSuffix("万亿"), "Int.min should use the largest Chinese quantity")
}
