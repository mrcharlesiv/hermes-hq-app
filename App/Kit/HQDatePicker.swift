// [mac] Mac polish #108: a compact date picker draws its value on the Mac as plain words ("10:00 PM", no box and no
// chevron), so Tasks Settings' quiet hours, New Task's day and time, a task's due time and a job's time didn't read as
// controls beside the stepper and pop-ups around them. On the Mac the value stands in the box the forms' fields and
// pop-ups share (`MacField`), at their height, its label leading as before. Elsewhere it is the plain DatePicker.

import SwiftUI

struct HQDatePicker: View {
    var title: String
    @Binding var selection: Date
    var components: DatePickerComponents

    init(_ title: String, selection: Binding<Date>, displayedComponents: DatePickerComponents = .hourAndMinute) {
        self.title = title
        _selection = selection
        components = displayedComponents
    }

    var body: some View {
        if DeviceWord.isMac {
            let _ = Theme.touch()
            let box = RoundedRectangle(cornerRadius: MacField.radius, style: .continuous)
            LabeledContent(title) {
                DatePicker(title, selection: $selection, displayedComponents: components)
                    .labelsHidden()
                    .padding(.horizontal, 4)
                    .frame(minHeight: MacForm.controlHeight)
                    .background(box.fill(MacField.fill))
                    .overlay(box.strokeBorder(MacField.stroke, lineWidth: 1).allowsHitTesting(false))
            }
        } else {
            DatePicker(title, selection: $selection, displayedComponents: components)
        }
    }
}
