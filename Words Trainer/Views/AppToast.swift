import SwiftUI

struct AppToast: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
    let systemImage: String
    let tint: Color

    static func == (lhs: AppToast, rhs: AppToast) -> Bool {
        lhs.id == rhs.id
    }
}

struct AppToastView: View {
    let toast: AppToast

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: toast.systemImage)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(toast.tint, in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(LovableSurface.foreground)
                Text(toast.message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LovableSurface.muted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.08), radius: 18, x: 0, y: 8)
        .accessibilityElement(children: .combine)
    }
}
