# builds the SmartSpore apk inside the container.
FROM ghcr.io/cirruslabs/flutter:stable
WORKDIR /app

# install dependencies first
COPY pubspec.* ./
RUN flutter pub get

# copy rest of the project
COPY . .

# error handling for git lfs pointer files for the model file
RUN test "$(stat -c%s lib/assets/model/MNv4_FP32_ver2.pte)" -gt 1000000 \
    || (echo "ERROR: model file is a Git LFS pointer. Run 'git lfs pull' first." && exit 1)

RUN flutter build apk --release
