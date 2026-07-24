// LandmarksScreen.swift — 我的地標（清單／編輯／刪除／手動新增＝入口③）
// 綁 LandmarkManager＋LocationVM（手動新增預設用當前位置）
import SwiftUI

struct LandmarksScreen: View {
    @Environment(LandmarkManager.self) private var manager
    @Environment(LocationVM.self) private var vm
    @State private var editing: Landmark? = nil
    @State private var adding = false
    @State private var deleting: Landmark? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("常去的地方取自己的名字，地名卡與足跡會優先用它。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(BearTheme.cream.opacity(0.5))
                    .padding(.horizontal, 6)

                if manager.landmarks.isEmpty {
                    EmptyStateBear(title: "還沒有地標",
                                   message: "把常去的地方命名，熊熊就會用你的話說位置。")
                } else {
                    VStack(spacing: 0) {
                        ForEach(manager.landmarks) { landmark in
                            LandmarkRow(landmark: landmark,
                                        onEdit: { editing = landmark },
                                        onDelete: { deleting = landmark })
                            if landmark.id != manager.landmarks.last?.id {
                                Rectangle().fill(.white.opacity(0.07)).frame(height: 0.5).padding(.leading, 16)
                            }
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 22)
                            .fill(BearTheme.surface)
                            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
                    )
                }

                Button { adding = true } label: {
                    Text("＋ 新增地標（用當前位置）")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(vm.current == nil ? BearTheme.cream.opacity(0.3) : BearTheme.honeyLight)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(
                            RoundedRectangle(cornerRadius: 18)
                                .strokeBorder((vm.current == nil ? BearTheme.cream.opacity(0.2) : BearTheme.honeyLight.opacity(0.45)),
                                              style: .init(lineWidth: 1.5, dash: [6, 5]))
                        )
                }
                .buttonStyle(.plain)
                .disabled(vm.current == nil)
                if vm.current == nil {
                    Text("目前沒有座標可用——先開回報拿到位置，再回來新增。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(BearTheme.cream.opacity(0.35))
                        .padding(.horizontal, 8)
                }
            }
            .padding(16)
            .padding(.bottom, 100)
        }
        .background(BearTheme.bg)
        .navigationTitle("我的地標")
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $adding) {
            if let cur = vm.current {
                LandmarkFormSheet(coordinate: cur.coordinate, suggestedName: cur.resolvedName ?? "")
            }
        }
        .sheet(item: $editing) { landmark in
            LandmarkFormSheet(coordinate: landmark.coordinate, editing: landmark)
        }
        .confirmationDialog("刪除「\(deleting?.alias ?? "")」？",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("刪除地標", role: .destructive) {
                if let l = deleting { manager.delete(id: l.id) }
                deleting = nil
            }
        } message: {
            Text("之後這一帶會回到通用地名。")
        }
    }
}

#Preview {
    NavigationStack { LandmarksScreen() }
        .environment(LandmarkManager())
        .environment(LocationVM())
        .preferredColorScheme(.dark)
}
