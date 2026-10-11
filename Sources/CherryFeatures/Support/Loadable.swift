import Foundation

public enum Loadable<Value: Equatable>: Equatable {
    case idle
    case loading
    case loaded(Value)
    case failed(String)

    public var value: Value? {
        if case .loaded(let v) = self { return v }
        return nil
    }

    public var isLoading: Bool { self == .loading }

    public var errorMessage: String? {
        if case .failed(let m) = self { return m }
        return nil
    }

    init(_ result: Result<Value, any Error>) {
        switch result {
        case .success(let v): self = .loaded(v)
        case .failure(let e): self = .failed(e.userMessage)
        }
    }
}
