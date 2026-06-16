import SwiftUI

struct ContentView: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.94, green: 0.98, blue: 1.0),
                    Color(red: 0.82, green: 0.91, blue: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 22) {
                Image(systemName: "archivebox.fill")
                    .font(.system(size: 68, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue, Color(red: 0.25, green: 0.55, blue: 0.9)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: .blue.opacity(0.18), radius: 14, x: 0, y: 8)

                VStack(spacing: 10) {
                    Text("しまい箱")
                        .font(.largeTitle.bold())
                        .foregroundStyle(Color(red: 0.08, green: 0.18, blue: 0.32))

                    Text("写真を端末内で安全に探すためのアプリ")
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Label("写真は外部送信しません", systemImage: "lock.shield.fill")
                    Label("読み取り専用で扱います", systemImage: "eye.fill")
                    Label("端末内で検索します", systemImage: "magnifyingglass")
                }
                .font(.callout)
                .foregroundStyle(Color(red: 0.10, green: 0.24, blue: 0.42))
                .padding(18)
                .frame(maxWidth: 340, alignment: .leading)
                .background(.white.opacity(0.76), in: RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.06), radius: 18, x: 0, y: 8)
            }
            .padding(28)
        }
    }
}

#Preview {
    ContentView()
}
