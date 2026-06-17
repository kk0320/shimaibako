import SwiftUI

struct SafetyPolicyCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SafetyPolicyRow(title: "写真は外部送信しません", systemImage: "lock.shield.fill")
            SafetyPolicyRow(title: "写真は読み取り専用で扱います", systemImage: "eye.fill")
            SafetyPolicyRow(title: "削除・移動・リネームは行いません", systemImage: "checkmark.shield.fill")
            SafetyPolicyRow(title: "検索は端末内で実行します", systemImage: "iphone")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.76), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct SafetyPolicyRow: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: systemImage)
                .font(.callout.weight(.semibold))
                .frame(width: 18, alignment: .center)

            Text(title)
                .font(.callout.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
                .minimumScaleFactor(0.9)
        }
        .foregroundStyle(Color(red: 0.10, green: 0.24, blue: 0.42))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
