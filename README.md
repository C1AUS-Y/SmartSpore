# SmartSpore

**SmartSpore** is a mobile app that helps foragers in the Philippines tell dangerous wild mushrooms apart from their edible look-alikes. Snap three photos of a mushroom (top, underside, and side) and the app identifies the most likely species and tells you whether it is toxic.

It was built as a thesis project at Holy Angel University, *"Enhancing Foraging Safety: A Low-Resource Machine Learning Model for Poisonous Mushroom Identification in the Philippines."*

> **Safety disclaimer:** SmartSpore is a research prototype and a decision-support aid, not a substitute for expert identification. **Never eat a wild mushroom based on the app's result alone.** Always have a qualified local expert confirm the identification.

---

## Features

- **Three-photo identification:** combines top (cap), bottom (gills), and side (stalk) photos for a more reliable result than a single image.
- **Hybrid offline / online models:**
  - **Offline:** a MobileNetV4-Large model that runs entirely on the device, so it works with no signal in the field.
  - **Online:** a Swin Transformer Base model served from the cloud for higher accuracy when you have internet access.
- **Toxicity warnings:** every result is clearly marked as toxic or edible, with guidance to avoid consumption and contact Poison Control or seek medical help if a toxic species has been eaten.
- **Explainable results:** shows the cap, gill, and stalk traits that distinguish the predicted species, plus per-photo confidence and agreement across photos.
- **Low-resource friendly:** tested on a low-end Android device (average offline latency of about 5 seconds).
- **Reproducible build:** a Dockerfile builds the release APK without installing Flutter or Android tooling locally.

### Supported species

| Species | Common name | Status |
|---|---|---|
| *Agaricus xanthodermus* | Yellow Stainer | Toxic |
| *Chlorophyllum molybdites* | Green-Spored Parasol | Toxic |
| *Lepiota cristata* | Stinking Dapperling | Toxic |
| *Agaricus campestris* | Field Mushroom | Edible |
| *Chlorophyllum rhacodes* | Shaggy Parasol | Edible |
| *Macrolepiota procera* | Parasol Mushroom | Edible |

---

## Repository structure

| Path | Description |
|---|---|
| `smartspore_app/` | Flutter mobile app (source, Dockerfile, assets, bundled offline model) |
| `Model Training Scripts/` | Google Colab notebook used to train and evaluate the models (see its own README) |
| `*.pdf` | Research manuscript, editor's note, plagiarism certificate, and ACM paper |

---

## Build the APK with Docker

The easiest way to build SmartSpore. Everything (Flutter SDK, Android SDK, dependencies) is handled inside the container.

### Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) (or Docker Engine on Linux), running
- [Git LFS](https://git-lfs.com/): the offline ML model (`.pte`, about 125 MB) is stored with Git LFS
  
### Steps

**1. Clone the repo and pull the model file**

```bash
git lfs install
git clone https://github.com/<your-username>/SmartSpore.git
cd SmartSpore
git lfs pull
```

**2. Build the image** (from the `smartspore_app` folder)

```bash
cd smartspore_app
docker build -t smartspore-apk .
```

The first build can take several minutes while it downloads dependencies and compiles the release APK. Later builds are faster thanks to layer caching.

**3. Copy the APK out of the container**

```bash
docker create --name smartspore-tmp smartspore-apk
docker cp smartspore-tmp:/app/build/app/outputs/flutter-apk/app-release.apk ./SmartSpore.apk
docker rm smartspore-tmp
```

`SmartSpore.apk` now appears in your current folder.

**4. Install on an Android phone**

Copy `SmartSpore.apk` to the phone and open it (you may need to allow "Install unknown apps" for your file manager or browser). Or, with USB debugging enabled:

```bash
adb install SmartSpore.apk
```

### Troubleshooting

- **`ERROR: model file is a Git LFS pointer. Run 'git lfs pull' first.`**
  The build checks that the real model file is present. Run `git lfs pull` in the repo, then rebuild.
- **Build is slow or runs out of memory:** increase the memory allocated to Docker in Docker Desktop settings (4 GB+ recommended).
- **Rebuild from scratch:** `docker build --no-cache -t smartspore-apk .`

---

## Run locally without Docker (optional)

Requires the [Flutter SDK](https://docs.flutter.dev/get-started/install) and an Android device or emulator.

```bash
cd smartspore_app
git lfs pull
flutter pub get
flutter run
```

## Using the app

1. Open SmartSpore and choose a model: **Offline** (on-device) or **Online** (Swin, needs internet).
2. Take the three requested photos: top of the cap, the gills underneath, and the stalk from the side.
3. Review the predicted species, confidence, toxicity warning, and the traits that support the result.
4. Confirm with a local expert before consuming anything.

---

## Training the models

Model training and evaluation code lives in `Model Training Scripts/Relevent_codes.ipynb`, a Google Colab notebook. A GPU with at least 12 GB of VRAM is needed for the MobileNetV4 and Swin training sections. See [`Model Training Scripts/README.md`](Model%20Training%20Scripts/README.md) for details.

## Tech stack

Flutter · Dart · ExecuTorch (on-device inference) · PyTorch · MobileNetV4 · Swin Transformer · Docker

## Authors

Bianca Claire L. Ochoa, Bianca Venice L. Ochoa, Hans Christian S. Ocampo, and Danielle Laurence B. Lenon, School of Computing, Holy Angel University. Adviser: Everly M. Chua, DIT.

## License

Released under the MIT License. See [`smartspore_app/LICENSE`](smartspore_app/LICENSE).
