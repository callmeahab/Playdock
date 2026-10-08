import SwiftUI
import PlaydockCore

struct CollectionsView:View {
    @ObservedObject var model:LauncherModel
    @Environment(\.dismiss) private var dismiss
    @State private var edit=GameCollection(name:"")
    @State private var message=""
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            HStack { Text("Collections & folders").font(.title2.bold()); Spacer(); Button("Done") { dismiss() }.couchControl("Done").keyboardShortcut(.cancelAction) }
            HStack(alignment:.top,spacing:22) {
                ScrollView {
                    VStack(alignment:.leading,spacing:10) {
                        ForEach(model.collections) { collection in
                            Button { edit=collection; message="" } label: {
                                VStack(alignment:.leading,spacing:4) { Label(collection.name,systemImage:collection.rule == .manual ? "folder" : "line.3.horizontal.decrease.circle"); Text(collection.rule.title).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth:.infinity,alignment:.leading).padding(12).glassPanel(radius:12)
                            }.buttonStyle(ControllerButtonStyle(style: .plain))
                        }
                    }
                }.frame(width:220)
                VStack(alignment:.leading,spacing:15) {
                    TextField("Collection name",text:$edit.name).textFieldStyle(.roundedBorder)
                    Picker("Group",selection:$edit.rule) { ForEach(CollectionRule.allCases,id:\.self) { Text($0.title).tag($0) } }
                    if edit.rule == .tag { TextField("Match tag",text:$edit.tag).textFieldStyle(.roundedBorder) }
                    Picker("Parent folder",selection:Binding(get:{edit.parentID ?? "none"},set:{edit.parentID=$0 == "none" ? nil : $0})) {
                        Text("None").tag("none")
                        ForEach(model.collections.filter{!GameCollection.descendants(of:edit.id,in:model.collections).contains($0.id)}) { Text($0.name).tag($0.id) }
                    }
                    Text("A parent folder includes games from its child collections. Add games to manual collections from their game settings.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("New") { edit=GameCollection(name:""); message="" }
                        Spacer(); Button("Save") { do { try model.saveCollection(edit); message="Saved" } catch { message=error.localizedDescription } }
                    }
                    if model.collections.contains(where:{$0.id==edit.id}) { Button("Delete collection",role:.destructive) { model.deleteCollection(edit); edit=GameCollection(name:""); message="Collection removed; games remain in your library." } }
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth:.infinity,alignment:.leading)
            }
        }.padding(26).frame(width:700,height:480)
        .background(DialogEscapeHandler { dismiss() }.allowsHitTesting(false))
    }
}
