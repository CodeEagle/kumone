import KumoneCore
import SwiftUI

/// Links the current track metadata to its artist and album without requiring
/// the immersive presentation to own a second navigation stack.
struct NowPlayingTrackDestinationLinks: View {
    let track: Track
    let font: Font
    let color: Color
    let onOpenDestination: (Destination) -> Void
    var allowsWrapping = false

    private var artists: [ArtistRef] {
        track.artists.filter { $0.id > 0 && !$0.name.isEmpty }
    }

    @ViewBuilder
    var body: some View {
        if allowsWrapping {
            Text(linkedMetadata)
                .font(font)
                .foregroundStyle(color)
                .tint(color)
                .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 3)
                .environment(\.openURL, OpenURLAction { url in
                    guard let destination = Self.destination(for: url) else { return .discarded }
                    onOpenDestination(destination)
                    return .handled
                })
        } else {
            singleLineLinks
        }
    }

    var linkedMetadata: AttributedString {
        var text = AttributedString()
        if artists.isEmpty {
            text.append(AttributedString(track.artistNames))
        } else {
            for (index, artist) in artists.enumerated() {
                if index > 0 { text.append(AttributedString(" / ")) }
                var name = AttributedString(artist.name)
                name.link = URL(string: "kumone-destination://artist/\(artist.id)")
                name.foregroundColor = color
                text.append(name)
            }
        }
        if track.album.id > 0, !track.album.name.isEmpty {
            if !text.characters.isEmpty { text.append(AttributedString(" — ")) }
            var album = AttributedString(track.album.name)
            album.link = URL(string: "kumone-destination://album/\(track.album.id)")
            album.foregroundColor = color
            text.append(album)
        }
        return text
    }

    static func destination(for url: URL) -> Destination? {
        guard url.scheme == "kumone-destination",
              let id = Int(url.lastPathComponent), id > 0 else { return nil }
        switch url.host {
        case "artist": return .artist(id)
        case "album": return .album(id)
        default: return nil
        }
    }

    private var singleLineLinks: some View {
        HStack(spacing: 0) {
            if artists.isEmpty {
                Text(track.artistNames)
            } else {
                ForEach(Array(artists.enumerated()), id: \.offset) { index, artist in
                    if index > 0 {
                        Text(" / ")
                    }
                    Button {
                        onOpenDestination(.artist(artist.id))
                    } label: {
                        Text(artist.name)
                            .contentShape(Rectangle())
                            .padding(.vertical, 3)
                    }
                    .buttonStyle(.scalePress)
                    .accessibilityLabel("打开歌手：\(artist.name)")
                }
            }

            if track.album.id > 0, !track.album.name.isEmpty {
                if !track.artistNames.isEmpty {
                    Text(" — ")
                }
                Button {
                    onOpenDestination(.album(track.album.id))
                } label: {
                    Text(track.album.name)
                        .contentShape(Rectangle())
                        .padding(.vertical, 3)
                }
                .buttonStyle(.scalePress)
                .accessibilityLabel("打开专辑：\(track.album.name)")
            }
        }
        .font(font)
        .foregroundStyle(color)
        .lineLimit(1)
        .accessibilityElement(children: .contain)
    }
}
