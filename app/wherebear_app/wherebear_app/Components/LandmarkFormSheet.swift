// LandmarkFormSheet.swift — 地標命名表單（三入口共用：長停留卡／stay 命名／手動新增與編輯）
// 綁 LandmarkManager.create / update / resolvePreview（重疊提示）
import SwiftUI
import MapKit

struct LandmarkFormSheet: View {
    @Environment(LandmarkManager.self) private var manager
    @Environment(\.dismiss) private var dismiss
    var coordinate: CLLocationCoordinate2D
    var suggestedName: String = ""
    var editing: Landmark? = nil
    var onSaved: (String) -> Void = { _ in }   // 存好回報名稱 → 呼叫端即時刷新（免等重載）

    @State private var alias = ""
    @State private var preset: RadiusPreset = .place
    @State private var customRadius: Double = 100
    @State private var camera: MapCameraPosition = .automatic

    private var radius: Int { preset.meters ?? Int(customRadius) }
    private var overlap: Landmark? {
        guard editing == nil else { return nil }
        return manager.resolvePreview(coordinate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(editing == nil ? "幫這裡命名" : "編輯地標")
                .font(.system(size: 21, weight: .heavy))
                .foregroundStyle(BearTheme.cream)
                .padding(.top, 22)

            HStack(spacing: 10) {
                Image(systemName: "tag")
                    .font(.system(size: 15))
                    .foregroundStyle(BearTheme.cream.opacity(0.45))
                    .frame(width: 20)
                TextField("名稱（例如：家、健身房）", text: $alias)
                    .font(.system(size: 16))
                    .foregroundStyle(BearTheme.cream)
            }
            .padding(.horizontal, 18)
            .frame(height: 52)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(.white.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
            )

            Map(position: $camera) {
                MapCircle(center: coordinate, radius: Double(radius))
                    .foregroundStyle(BearTheme.honey.opacity(0.2))
                    .stroke(BearTheme.honeyLight.opacity(0.8), lineWidth: 1.5)
                Annotation("", coordinate: coordinate) {
                    Circle().fill(BearTheme.honeyLight)
                        .frame(width: 14, height: 14)
                        .overlay(Circle().strokeBorder(BearTheme.cream, lineWidth: 2))
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .allowsHitTesting(false)
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .onChange(of: radius, initial: true) {
                camera = .region(MKCoordinateRegion(
                    center: coordinate,
                    latitudinalMeters: Double(radius) * 4.5,
                    longitudinalMeters: Double(radius) * 4.5
                ))
            }

            RadiusPresetPicker(preset: $preset, customRadius: $customRadius)

            if let overlap {
                InlineNotice(kind: .warning, text: "這個點已在「\(overlap.alias)」的範圍內，確定要再建一個？")
            }

            PrimaryButton(title: "儲存") {
                let name = alias.trimmingCharacters(in: .whitespaces)
                let finalName: String
                if var l = editing {
                    finalName = name.isEmpty ? l.alias : name
                    l.alias = finalName
                    l.radius = radius
                    manager.update(l)
                } else {
                    finalName = name.isEmpty ? "未命名" : name
                    manager.create(alias: finalName, coordinate: coordinate, radius: radius)
                }
                onSaved(finalName)
                dismiss()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .presentationDetents([.height(editing == nil && overlap != nil ? 620 : 560)])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color(hex: 0x241D15))
        .onAppear {
            if let editing {
                alias = editing.alias
                preset = RadiusPreset.matching(editing.radius)
                customRadius = Double(editing.radius)
            } else {
                alias = suggestedName
            }
        }
    }
}
