import Foundation
import PDFKit
import RudelEngine
import SwiftData
import Testing

@testable import Rudel

/// Tierarzt-Bericht: Auswahl der Inhalte (reiner Wert) und das gerenderte PDF.
///
/// Geprüft werden `Date`-Werte statt formatierter Texte — `Format` richtet sich
/// nach der Gerätezeitzone, die Fixtures rechnen in UTC.
@MainActor
@Suite("Tierarzt-Bericht")
struct VetReportTests {

    private let asOf = Fixture.day(2026, 10, 5)

    private func makePet(
        in context: ModelContext,
        species: Species = .dog,
        isFemale: Bool = true,
        isNeutered: Bool = false
    ) -> Pet {
        let pet = Pet(name: "Zola", species: species, isFemale: isFemale, isNeutered: isNeutered, createdAt: Fixture.logged)
        context.insert(pet)
        return pet
    }

    @discardableResult
    private func addAppointment(
        _ pet: Pet, on date: Date, status: AppointmentStatus, title: String = "Kontrolle",
        questions: String = "", findings: String = "", in context: ModelContext
    ) -> VetAppointment {
        let appointment = VetAppointment(
            date: date, title: title, preparationNotes: questions, findings: findings,
            status: status, createdAt: Fixture.logged
        )
        context.insert(appointment)
        appointment.pet = pet
        return appointment
    }

    private func addSymptom(_ pet: Pet, on date: Date, in context: ModelContext) {
        let entry = SymptomEntry(date: date, type: .vomiting, loggedAt: Fixture.logged)
        context.insert(entry)
        entry.pet = pet
    }

    private func addWeight(_ pet: Pet, _ kg: Double, on date: Date, in context: ModelContext) {
        let entry = WeightEntry(date: date, valueKg: kg, loggedAt: Fixture.logged)
        context.insert(entry)
        entry.pet = pet
    }

    // MARK: Symptom-Zeitraum

    @Test("Symptome ab dem letzten erledigten Termin, wenn der länger als 90 Tage zurückliegt")
    func symptomsSinceLastDoneVisit() throws {
        let context = try makeContext()
        let pet = makePet(in: context)
        addAppointment(pet, on: Fixture.day(2026, 3, 10), status: .done, in: context)
        // Abgesagt und geplant zählen nicht als Besuch.
        addAppointment(pet, on: Fixture.day(2026, 8, 1), status: .cancelled, in: context)
        addSymptom(pet, on: Fixture.day(2026, 3, 9), in: context)
        addSymptom(pet, on: Fixture.day(2026, 4, 2), in: context)
        addSymptom(pet, on: Fixture.day(2026, 9, 30), in: context)
        try context.save()

        let content = VetReportContent(pet: pet, appointment: nil, asOf: asOf, dayMath: .utc)
        #expect(content.symptomsSince == Fixture.day(2026, 3, 10))
        #expect(content.symptoms.map(\.date) == [Fixture.day(2026, 9, 30), Fixture.day(2026, 4, 2)])
    }

    @Test("Ein kürzlicher Besuch verkürzt den Rückblick nicht unter 90 Tage")
    func symptomsAtLeastNinetyDays() throws {
        let context = try makeContext()
        let pet = makePet(in: context)
        addAppointment(pet, on: Fixture.day(2026, 9, 28), status: .done, in: context)
        addSymptom(pet, on: Fixture.day(2026, 7, 10), in: context)
        addSymptom(pet, on: Fixture.day(2026, 6, 1), in: context)
        try context.save()

        let content = VetReportContent(pet: pet, appointment: nil, asOf: asOf, dayMath: .utc)
        #expect(content.symptomsSince == Fixture.day(2026, 7, 7))
        #expect(content.symptoms.map(\.date) == [Fixture.day(2026, 7, 10)])
    }

    @Test("Der Anlass-Termin selbst zählt nicht als letzter Besuch")
    func occasionIsNotThePreviousVisit() throws {
        let context = try makeContext()
        let pet = makePet(in: context)
        addAppointment(pet, on: Fixture.day(2026, 1, 15), status: .done, in: context)
        let occasion = addAppointment(pet, on: Fixture.day(2026, 9, 1), status: .done, in: context)
        try context.save()

        let content = VetReportContent(pet: pet, appointment: occasion, asOf: asOf, dayMath: .utc)
        #expect(content.symptomsSince == Fixture.day(2026, 1, 15))
        #expect(content.appointments.map(\.date) == [Fixture.day(2026, 1, 15)])
    }

    // MARK: Gewicht

    @Test("Gewicht der letzten 12 Monate mit Spanne und Trend")
    func weightTrend() throws {
        let context = try makeContext()
        let pet = makePet(in: context)
        addWeight(pet, 40, on: Fixture.day(2025, 9, 1), in: context) // älter als 12 Monate
        addWeight(pet, 30, on: Fixture.day(2025, 11, 1), in: context)
        addWeight(pet, 29.5, on: Fixture.day(2026, 3, 1), in: context)
        addWeight(pet, 32, on: Fixture.day(2026, 9, 1), in: context)
        try context.save()

        let weight = try #require(VetReportContent(pet: pet, appointment: nil, asOf: asOf, dayMath: .utc).weight)
        #expect(weight.points.map(\.kg) == [30, 29.5, 32])
        #expect(weight.minKg == 29.5)
        #expect(weight.maxKg == 32)
        #expect(weight.deltaKg == 2)
        #expect(weight.trend == .rising)
    }

    @Test("Kleine Schwankungen gelten als stabil")
    func weightStable() throws {
        let context = try makeContext()
        let pet = makePet(in: context)
        addWeight(pet, 30, on: Fixture.day(2026, 1, 1), in: context)
        addWeight(pet, 30.4, on: Fixture.day(2026, 9, 1), in: context)
        try context.save()

        let weight = try #require(VetReportContent(pet: pet, appointment: nil, asOf: asOf, dayMath: .utc).weight)
        #expect(weight.trend == .stable)
    }

    // MARK: Zyklus

    @Test("Läufigkeit nur bei unkastrierten Hündinnen")
    func cycleOnlyForIntactFemaleDogs() throws {
        let context = try makeContext()
        let female = makePet(in: context)
        let male = makePet(in: context, isFemale: false)
        let cat = makePet(in: context, species: .cat)
        for pet in [female, male, cat] {
            let period = CyclePeriod(day1Date: Fixture.day(2026, 4, 1), createdAt: Fixture.logged)
            context.insert(period)
            period.pet = pet
        }
        try context.save()

        let femaleReport = VetReportContent(pet: female, appointment: nil, asOf: asOf, dayMath: .utc)
        #expect(femaleReport.cycle?.periods.map(\.day1) == [Fixture.day(2026, 4, 1)])
        #expect(femaleReport.sections.contains { $0.title == "Läufigkeit" })
        #expect(VetReportContent(pet: male, appointment: nil, asOf: asOf, dayMath: .utc).cycle == nil)
        let catReport = VetReportContent(pet: cat, appointment: nil, asOf: asOf, dayMath: .utc)
        #expect(catReport.cycle == nil)
        #expect(!catReport.sections.contains { $0.title == "Läufigkeit" })
    }

    // MARK: Anlass

    @Test("Aus einem Termin heraus stehen die Fragen an die Praxis im Bericht")
    func occasionCarriesQuestions() throws {
        let context = try makeContext()
        let pet = makePet(in: context)
        let practice = VetPractice(name: "Praxis am Park", createdAt: Fixture.logged)
        context.insert(practice)
        let appointment = addAppointment(
            pet, on: Fixture.day(2026, 10, 12), status: .planned, title: "Impfung",
            questions: "Juckreiz am Ohr ansehen", in: context
        )
        appointment.practice = practice
        try context.save()

        let content = VetReportContent(pet: pet, appointment: appointment, asOf: asOf, dayMath: .utc)
        #expect(content.occasion?.questions == "Juckreiz am Ohr ansehen")
        #expect(content.occasion?.practiceName == "Praxis am Park")
        let occasion = try #require(content.sections.first { $0.title == "Anlass" })
        #expect(occasion.rows.contains { $0.text == "Juckreiz am Ohr ansehen" })

        let general = VetReportContent(pet: pet, appointment: nil, asOf: asOf, dayMath: .utc)
        #expect(!general.sections.contains { $0.title == "Anlass" })
    }

    @Test("Dauermedikamente und Vorsorge stehen getrennt")
    func medicationsSplitByKind() throws {
        let context = try makeContext()
        let pet = makePet(in: context)
        let ongoing = MedicationPlan(kind: .ongoing, productName: "Apoquel", doseTimesMinutes: [480], createdAt: Fixture.logged)
        let rabies = MedicationPlan(kind: .rabiesVaccination, productName: "Nobivac", effectiveDays: 1095, createdAt: Fixture.logged)
        let stopped = MedicationPlan(kind: .dewormer, productName: "Alt", intervalDays: 90, isActive: false, createdAt: Fixture.logged)
        for plan in [ongoing, rabies, stopped] {
            context.insert(plan)
            plan.pet = pet
        }
        try context.save()

        let content = VetReportContent(pet: pet, appointment: nil, asOf: asOf, dayMath: .utc)
        #expect(content.medications.map(\.title) == ["Apoquel"])
        // Impfungen heißen nach der Krankheit, das Präparat steht daneben.
        #expect(content.preventives.map(\.title) == ["Tollwut"])
        #expect(content.preventives.map(\.kind) == ["Nobivac"])
    }

    // MARK: PDF

    @Test("Das PDF enthält Tiername und Abschnittstitel")
    func renderedTextContainsSections() throws {
        let context = try makeContext()
        let pet = makePet(in: context)
        addWeight(pet, 30, on: Fixture.day(2026, 9, 1), in: context)
        try context.save()

        let content = VetReportContent(pet: pet, appointment: nil, asOf: asOf, dayMath: .utc)
        let document = try #require(PDFDocument(data: VetReportRenderer.render(content)))
        #expect(document.pageCount >= 1)
        let text = try #require(document.string)
        #expect(text.contains("Zola"))
        for title in ["Tier und Notfalldaten", "Aktuelle Medikamente", "Impfungen und Vorsorge", "Letzte Tierarzttermine", "Seite 1 von"] {
            #expect(text.contains(title), "\(title)")
        }
    }

    @Test("Viele Einträge ergeben mehrere Seiten mit Seitenzahlen")
    func manyEntriesSpanPages() throws {
        let context = try makeContext()
        let pet = makePet(in: context)
        for offset in 0..<85 {
            addSymptom(pet, on: Fixture.day(2026, 7, 10).addingTimeInterval(Double(offset) * 86_400), in: context)
        }
        try context.save()

        let content = VetReportContent(pet: pet, appointment: nil, asOf: asOf, dayMath: .utc)
        let document = try #require(PDFDocument(data: VetReportRenderer.render(content)))
        #expect(document.pageCount > 1)
        let lastPage = try #require(document.page(at: document.pageCount - 1)?.string)
        #expect(lastPage.contains("Seite \(document.pageCount) von \(document.pageCount)"))
    }

    @Test("Dateiname mit Tiername und Datum")
    func fileName() {
        #expect(
            VetReportFile.fileName(petName: "Zola / Mia", date: asOf, calendar: Fixture.calendar)
                == "Rudel-Bericht-Zola-Mia-2026-10-05.pdf"
        )
    }
}
