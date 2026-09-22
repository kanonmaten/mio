# Mio

Privat iPhone-app för svensk lokal transkription, anteckningar och planering. Byggd i SwiftUI för iOS 26+, med iPhone 13 som måltelefon. Ingen App Store-distribution.

**Aktuell utvecklingsversion: v0.2.0 — ej släppt.** Funktionerna finns i källkod; den aktuella revisionen behöver byggas, testas och installeras. Det äldre korta telefonprovet gäller bara v0.1.0-prototypen. Se [status](docs/STATUS.md).

## Vad finns?

- Fem flikar: **Mio**, **Tidslinje**, **Kalender**, **Anteckningar**, **Morgon**.
- Lokal svensk transkription, upptäckt av ordet Mio, paus/stopp och sessionsdiagnostik.
- Manuella tidslinjeposter, anteckningar, uppgifter, planer och uttryckliga minnen; skapa, sök, redigera, slutför och radera.
- Sessionsrubriker, anteckningar och rättad visningstext som bevarar original och ljudtider.
- Lokal JSON-lagring och export. Ingen råljudslagring, moln-AI, systemkalender eller systemalarm.

## Hitta rätt

| Behöver du… | Läs |
|---|---|
| Se vad som ändrats | [CHANGELOG](CHANGELOG.md) |
| Förstå versioner och nästa steg | [Roadmap](docs/ROADMAP.md) |
| Se vad som faktiskt är verifierat | [Status](docs/STATUS.md) |
| Bygga och installera på iPhone | [Installation](docs/INSTALLATION.md) |
| Arbeta med koden | [AGENTS](AGENTS.md), [arbetsflöde](docs/WORKFLOW.md) |
| Förstå produkten och tekniska regler | [Vision](docs/PRODUKTVISION.md), [beslut](docs/DECISIONS.md), [datamodell](docs/DATAMODELL.md) |
| Testa appen | [v0.2-testplan](docs/TESTPLAN_V0_2.md), [transkription och långtest](docs/TESTPLAN_V0_1.md) |

## Utveckling

Öppna `Mio.xcodeproj`, välj schemat **Mio**. Appkod ligger i `Mio/`, XCTest i `MioTests/` och molnbygget i `.github/workflows/build-unsigned-ipa.yml`.

Linux, Windows och den äldre Monterey-Macen används för redigering och Git. iOS-kompilering och XCTest kräver en kompatibel Mac med Xcode eller GitHub Actions. Workflowen konfigurerar Xcode 26.6 för IPA och ett separat, icke blockerande Xcode 27-previewjobb; runnernas tillgänglighet måste kontrolleras vid körning.

## Integritet och kompatibilitet

Lyssning startas av användaren. Spela bara in andra med tydligt samtycke och enligt skolans, arbetsplatsens och lokala regler. Mikrofonljud bearbetas i minnet; exporter kan innehålla känslig text och ska stanna utanför repot.

Appidentiteten `se.eyvin.MioPhaseOne` och befintliga interna lagringsvägar behålls för uppgradering på plats. De äldre namnen är kompatibilitetsvärden, inte versionsnamn. Projekt, target, scheme och produkt heter **Mio** även i kommande versioner.
