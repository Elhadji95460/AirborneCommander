# Airborne Commander

Poste de commandement **macOS** (SwiftUI) pour une flotte de mini‑drones **Parrot Airborne Night**, pilotée à travers des iPhones‑relais et un cerveau IA.

Le Mac raisonne et décide ; il ne touche jamais au Bluetooth. Chaque iPhone (application [Drone Flotte](../DroneFlotte)) tient 1 à 2 drones en BLE et exécute les ordres reçus en WiFi. Toute commande de vol descend **Mac → WebSocket → iPhone → BLE → drone**, et toute mesure remonte en sens inverse.

## Fonctions principales

- **Groupes de mission A–D** avec **décollage séquentiel** (un drone après l'autre) puis mission simultanée.
- **Modes par drone** : IA 100 % (autonome) · Semi‑IA · Manuel (manette PS5 DualSense ou voix).
- **Serveur WebSocket** (`Network.framework`, port 5570) + **annonce Bonjour** (`_airbornecmd._tcp`) pour que les iPhones trouvent le Mac sans saisir d'IP.
- **Handover** automatique entre iPhones sur signal faible, et **reprise** d'un drone orphelin quand un iPhone disparaît.
- **Intérieur / Extérieur** : plafond d'altitude et longueur des trajets adaptés.
- **Cerveau Claude (API, optionnel)** : analyse des photos du sol et débrief d'apprentissage ; l'IA locale prend le relais sans clé.
- **Réseau de neurones évolutif** : un vrai perceptron multicouche entraîné par rétropropagation, avec **neurogenèse** (de nouveaux neurones poussent) et **élagage** — visualisé en direct.
- **Vision GPU** (Metal Performance Shaders) préparée mais volontairement **débranchée**.
- **Contrôle vocal** (français, Speech framework) et **retour image** (FTP Bluetooth, photos sauvées sur le Bureau).
- **Apprentissage persistant** : mémoire de secteurs, journal de vol et poids du réseau survivent aux redémarrages.

## Architecture

| Module | Rôle |
|---|---|
| `FleetEngine` | Intelligence centrale : état, groupes, missions, handover, reprise, mémoire. |
| `CommandServer` | Serveur WebSocket + Bonjour ; reçoit hello/télémétrie/photos, envoie les commandes. |
| `ClaudeBrain` | Liaison API Claude (vision + débrief), optionnelle. |
| `NeuralMemory` + `NeuralView` | Réseau de neurones évolutif + sa visualisation. |
| `GPUVision` | Vision d'obstacles sur GPU (Metal) — prête, non connectée. |
| `VisionAI` | Analyse d'image locale (CPU). |
| `SpeechController` | Contrôle vocal. |
| `DualSenseManager` | Manette PS5. |

## Build

```sh
xcodebuild -project AirborneCommander.xcodeproj -scheme AirborneCommander build
open "$(xcodebuild -project AirborneCommander.xcodeproj -scheme AirborneCommander -showBuildSettings | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')/AirborneCommander.app"
```

macOS 14+. Signature ad‑hoc pour le développement local.

## Contraintes matérielles (honnêtes)

Liaison Bluetooth LE ~20 m même en extérieur · pas de vidéo en direct (photos par FTP, 20–60 s, drone posé) · autonomie 7–9 min par charge.

## Sécurité

La clé API Claude est saisie par l'utilisateur, stockée **localement** sur le Mac, jamais écrite dans les sources ni journalisée. Les commandes de vol sont soumises à un interrupteur de consentement côté téléphone ; atterrissage et urgence sont toujours permis.
