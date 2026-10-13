# SmartSpore

## Build the APK with Docker

Requires [Docker Desktop](https://www.docker.com/products/docker-desktop/) and
[Git LFS](https://git-lfs.com/) (the ML model file is stored with Git LFS, so run `git lfs pull` after cloning).

From the `smartspore_app` folder:

```bash
docker build -t smartspore-apk .
docker create --name smartspore-tmp smartspore-apk
docker cp smartspore-tmp:/app/build/app/outputs/flutter-apk/app-release.apk ./SmartSpore.apk
docker rm smartspore-tmp
```

`SmartSpore.apk` appears in the current folder. Copy it to an Android phone and install it.
