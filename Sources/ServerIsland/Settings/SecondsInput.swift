import SwiftUI

/// 使用数值绑定和原生步进器；空标题配合 labelsHidden 避免 Form 把占位数字当成第二个标签。
struct SecondsInput: View {
    @Binding var value: Int
    private static let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.allowsFloats = false
        formatter.minimum = 0
        formatter.maximum = NSNumber(value: Int.max)
        return formatter
    }()
    var body: some View {
        HStack(spacing: 3) {
            TextField("", value: $value, formatter: Self.formatter)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 70)
                .accessibilityLabel(L("停留时长（秒）", "Stay duration in seconds"))
            Stepper("", value: $value, in: 0...Int.max, step: 1)
                .labelsHidden().fixedSize().controlSize(.small)
                .accessibilityLabel(L("增加或减少秒数", "Increase or decrease seconds"))
        }
        .fixedSize()
    }
}
