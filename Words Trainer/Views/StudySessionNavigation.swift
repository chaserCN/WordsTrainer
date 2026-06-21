import SwiftUI

private struct StudySessionDestinationModifier: ViewModifier {
    @Binding var session: StudySession?
    @Binding var isPresented: Bool
    let store: DeckStore?
    let deckTitle: String

    func body(content: Content) -> some View {
        content.navigationDestination(isPresented: $isPresented) {
            if let session, let store {
                StudySessionView(session: session, store: store, deckTitle: deckTitle)
            }
        }
    }
}

private struct StudyStartErrorAlertModifier: ViewModifier {
    @Binding var message: String?
    let title: String

    func body(content: Content) -> some View {
        content.alert(L10n.text(title), isPresented: isPresented) {
            Button("ОК", role: .cancel) {
                message = nil
            }
        } message: {
            Text(message ?? "")
        }
    }

    private var isPresented: Binding<Bool> {
        Binding(
            get: { message != nil },
            set: { presented in
                if !presented {
                    message = nil
                }
            }
        )
    }
}

extension View {
    func studySessionDestination(
        session: Binding<StudySession?>,
        isPresented: Binding<Bool>,
        store: DeckStore?,
        deckTitle: String
    ) -> some View {
        modifier(
            StudySessionDestinationModifier(
                session: session,
                isPresented: isPresented,
                store: store,
                deckTitle: deckTitle
            )
        )
    }

    func studyStartErrorAlert(
        _ message: Binding<String?>,
        title: String = "Не удалось начать упражнение"
    ) -> some View {
        modifier(StudyStartErrorAlertModifier(message: message, title: title))
    }
}
