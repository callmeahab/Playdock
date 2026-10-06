import SwiftUI
import WayfarerCore

struct DownloadPolicyView:View {
    @ObservedObject var model:LauncherModel
    let client:GamePlatform
    @State private var policy=DownloadPolicy()
    @State private var expanded=false
    var body:some View {
        DisclosureGroup(isExpanded:$expanded) {
            VStack(alignment:.leading,spacing:14) {
                HStack { Text("Bandwidth limit"); Spacer(); TextField("Unlimited",value:$policy.bandwidthKBps,format:.number).textFieldStyle(.roundedBorder).frame(width:110); Text("KB/s").foregroundStyle(.secondary) }
                Text("0 means unlimited.").font(.caption).foregroundStyle(.secondary)
                Toggle("Schedule downloads",isOn:$policy.enabled)
                if policy.enabled {
                    HStack {
                        Picker("From",selection:$policy.startHour) { ForEach(0..<24,id:\.self) { Text(String(format:"%02d:00",$0)).tag($0) } }
                        Picker("Until",selection:$policy.endHour) { ForEach(0..<24,id:\.self) { Text(String(format:"%02d:00",$0)).tag($0) } }
                    }
                    Text("Uses this Mac's local time. Wayfarer pauses queued downloads outside the window while running. Steam retains this window for automatic updates when Wayfarer is closed; manual installs then follow Steam's behavior.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                }
                HStack { Text(model.downloadPolicyMessages[client] ?? "").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Apply") { model.applyDownloadPolicy(policy,client:client) }.disabled(model.connectionBusy.contains(client)) }
            }.padding(.top,12)
        } label: { Label("\(client.name) · Schedule & bandwidth",systemImage:"clock") }
        .padding(18).glassPanel(radius:14)
        .task(id:model.downloadPolicyKey(client)) { let key=model.downloadPolicyKey(client); let value=await model.readDownloadPolicy(client); if !Task.isCancelled && key==model.downloadPolicyKey(client) { policy=value } }
    }
}
