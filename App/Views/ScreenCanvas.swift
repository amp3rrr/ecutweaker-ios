import SwiftUI
import UIKit

/// Absolute-positioned rendering of a DDT screen (ScreenActivity.drawScreen view part).
/// Geometry: DDT units / 8 × zoom (Android: convertToPixel); fonts: size × 2 × fontScale × zoom.
struct ScreenCanvas: View {
    @ObservedObject var vm: ScreenViewModel
    let screen: Layout.ScreenData
    let zoom: CGFloat
    let fontScale: CGFloat

    private func px(_ v: Int) -> CGFloat { CGFloat(v) / 8 * zoom }
    private func fontSize(_ size: Int) -> CGFloat { max(CGFloat(size) * 2 * fontScale * zoom, 5) }

    private func textColor(_ font: Layout.Font, _ explicit: Layout.Color?) -> Color {
        (explicit ?? font.color).swiftUI
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            screen.color.swiftUI
                .frame(width: px(screen.width), height: px(screen.height))

            ForEach(Array(screen.labels.enumerated()), id: \.offset) { _, label in
                labelView(label)
            }
            ForEach(Array(screen.displays.enumerated()), id: \.offset) { _, display in
                displayView(display)
            }
            ForEach(Array(screen.inputs.enumerated()), id: \.offset) { _, input in
                inputView(input)
            }
            ForEach(Array(screen.buttons.enumerated()), id: \.offset) { _, button in
                buttonView(button)
            }
        }
        .frame(width: px(screen.width), height: px(screen.height), alignment: .topLeading)
    }

    // MARK: Labels

    @ViewBuilder
    private func labelView(_ l: Layout.LabelData) -> some View {
        if l.text.uppercased().hasPrefix("::PIC:") {
            if let img = vm.image(for: l.text, button: false) {
                Image(uiImage: img)
                    .resizable()
                    .frame(width: px(l.rect.w), height: px(l.rect.h))
                    .offset(x: px(l.rect.x), y: px(l.rect.y))
            }
        } else {
            let alignment: Alignment = l.alignment == 2 ? .top : (l.alignment == 1 ? .topTrailing : .topLeading)
            let textAlign: TextAlignment = l.alignment == 2 ? .center : (l.alignment == 1 ? .trailing : .leading)
            Text(l.text)
                .font(.system(size: fontSize(l.font.size)))
                .foregroundColor(textColor(l.font, l.fontColor))
                .multilineTextAlignment(textAlign)
                .padding(.horizontal, 1)
                .frame(width: px(l.rect.w), height: px(l.rect.h), alignment: alignment)
                .background(l.color?.swiftUI ?? Color.clear)
                .clipped()
                .offset(x: px(l.rect.x), y: px(l.rect.y))
        }
    }

    // MARK: Displays (read-only values)

    @ViewBuilder
    private func displayView(_ d: Layout.DisplayData) -> some View {
        let bg = d.color?.swiftUI ?? Color.white
        let fg = textColor(d.font, d.fontColor)
        if d.width > 0 {
            Text(d.text)
                .font(.system(size: fontSize(d.font.size)))
                .foregroundColor(fg)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 2)
                .frame(width: px(d.width), height: px(d.rect.h), alignment: .leading)
                .background(bg)
                .offset(x: px(d.rect.x), y: px(d.rect.y))
        }
        Text(vm.values[d.text] ?? "---")
            .font(.system(size: fontSize(d.font.size), weight: .semibold, design: .monospaced))
            .foregroundColor(fg)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .padding(.horizontal, 3)
            .frame(width: max(px(d.rect.w - d.width), 4), height: px(d.rect.h), alignment: .leading)
            .background(bg)
            .overlay(Rectangle().stroke(Color.green.opacity(0.7), lineWidth: 1))
            .textSelection(.enabled)
            .offset(x: px(d.rect.x + d.width), y: px(d.rect.y))
    }

    // MARK: Inputs (editable values / lists)

    @ViewBuilder
    private func inputView(_ input: Layout.InputData) -> some View {
        let bg = input.color?.swiftUI ?? Color.white
        let fg = textColor(input.font, input.fontColor)
        if input.width > 0 {
            Text(input.text)
                .font(.system(size: fontSize(input.font.size)))
                .foregroundColor(fg)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 2)
                .frame(width: px(input.width), height: px(input.rect.h), alignment: .leading)
                .background(bg)
                .offset(x: px(input.rect.x), y: px(input.rect.y))
        }
        let w = max(px(input.rect.w - input.width), 30)
        let h = max(px(input.rect.h), 18)
        if vm.isPicker(input) {
            Menu {
                Picker(input.text, selection: vm.pickerBinding(input.text)) {
                    ForEach(vm.pickerItems(input), id: \.self) { Text($0).tag($0) }
                }
            } label: {
                HStack(spacing: 2) {
                    Text(vm.pickers[input.text] ?? "")
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                }
                .font(.system(size: fontSize(input.font.size)))
                .foregroundColor(.primary)
                .padding(.horizontal, 3)
                .frame(width: w, height: h)
                .background(Color(.secondarySystemBackground))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.blue.opacity(0.6), lineWidth: 1))
            }
            .offset(x: px(input.rect.x + input.width), y: px(input.rect.y))
        } else {
            TextField("", text: vm.inputBinding(input.text))
                .font(.system(size: fontSize(input.font.size), design: .monospaced))
                .foregroundColor(.black)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .padding(.horizontal, 3)
                .frame(width: w, height: h)
                .background(Color.white)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.red.opacity(0.7), lineWidth: 1))
                .offset(x: px(input.rect.x + input.width), y: px(input.rect.y))
        }
    }

    // MARK: Buttons

    @ViewBuilder
    private func buttonView(_ b: Layout.ButtonData) -> some View {
        let w = max(px(b.rect.w), 24)
        let h = max(px(b.rect.h), 22)
        if b.text.uppercased().hasPrefix("::BTN:") {
            if let img = vm.image(for: b.text, button: true) {
                Button { vm.press(b.uniqueName) } label: {
                    Image(uiImage: img).resizable().frame(width: w, height: h)
                }
                .disabled(vm.busy)
                .offset(x: px(b.rect.x), y: px(b.rect.y))
            }
        } else {
            Button { vm.press(b.uniqueName) } label: {
                Text(b.text)
                    .font(.system(size: fontSize(b.font.size), weight: .medium))
                    .lineLimit(2)
                    .minimumScaleFactor(0.5)
                    .frame(width: w, height: h)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .disabled(vm.busy)
            .offset(x: px(b.rect.x), y: px(b.rect.y))
        }
    }
}
