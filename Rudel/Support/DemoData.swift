#if DEBUG
import Foundation
import RudelEngine
import SwiftData

/// Beispieldaten für die App-Store-Screenshots. Nur in Debug-Builds und nur
/// mit `-rudelDemo` beim Start, und nur in einem leeren Store.
@MainActor
enum DemoData {
    static func seedIfRequested(in context: ModelContext) {
        guard ProcessInfo.processInfo.arguments.contains("-rudelDemo"),
              (try? context.fetchCount(FetchDescriptor<Pet>())) == 0
        else { return }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today)! }

        let zola = Pet(
            name: "Zola",
            species: .dog,
            breed: "Rhodesian Ridgeback",
            birthDate: calendar.date(byAdding: .month, value: -40, to: today),
            weightTargetMinKg: 30,
            weightTargetMaxKg: 34,
            isFemale: true,
            createdAt: day(-400)
        )
        zola.colorValue = .rust
        context.insert(zola)

        let mia = Pet(name: "Mia", species: .cat, breed: "Europäisch Kurzhaar", isNeutered: true, createdAt: day(-300))
        mia.colorValue = .plum
        context.insert(mia)

        for (offset, kg) in [(-150, 31.8), (-120, 32.4), (-90, 32.1), (-60, 32.9), (-30, 33.4), (-3, 33.1)] {
            let entry = WeightEntry(date: day(offset), valueKg: kg)
            context.insert(entry)
            entry.pet = zola
        }

        let joint = MedicationPlan(
            kind: .ongoing,
            productName: "Gelenktabletten",
            doseTimesMinutes: [8 * 60, 19 * 60],
            doseStartDate: day(-20),
            doseLabel: "1 Tablette",
            createdAt: day(-20)
        )
        context.insert(joint)
        joint.pet = zola
        joint.stockAmount = 9
        joint.stockUnit = "Tabletten"
        joint.packageSize = 60
        joint.stockCountedAt = today

        let worm = MedicationPlan(kind: .dewormer, productName: "Wurmkur", intervalDays: 90, createdAt: day(-200))
        context.insert(worm)
        worm.pet = zola
        let lastWorm = MedicationEvent(givenOn: day(-84))
        context.insert(lastWorm)
        lastWorm.plan = worm

        let ticks = MedicationPlan(kind: .tickProtection, productName: "Zeckenschutz", intervalDays: 84, effectiveDays: 84, createdAt: day(-200))
        context.insert(ticks)
        ticks.pet = zola
        let lastTicks = MedicationEvent(givenOn: day(-30))
        context.insert(lastTicks)
        lastTicks.plan = ticks

        let practice = VetPractice(name: "Tierarztpraxis am Park", veterinarian: "Dr. Lange", phone: "040 123456")
        context.insert(practice)
        zola.primaryPractice = practice
        let checkup = VetAppointment(date: calendar.date(byAdding: .hour, value: 10, to: day(5))!, reason: .checkup, title: "Jahrescheck")
        context.insert(checkup)
        checkup.pet = zola
        checkup.practice = practice

        let symptom = SymptomEntry(date: day(-6), type: .itching, note: "Kratzt sich am linken Ohr")
        context.insert(symptom)
        symptom.pet = zola

        try? context.save()
    }
}
#endif
