# Important: This Is a Google Colab Notebook, Not a Python Script

The file in this folder (`Relevent_codes.ipynb`) is a **Jupyter/Google Colab notebook**. It is designed to be opened and run in [Google Colab](https://colab.research.google.com/). It can also be opened locally in VS Code with the Jupyter extension.

---

## How to Run in Google Colab

1. Download `Relevent_codes.ipynb`.
2. Go to [Google Colab](https://colab.research.google.com/).
3. Click **Upload** at the top of the page, then click **Browse**.
4. Select `Relevent_codes.ipynb` from wherever you saved it.
5. The notebook will open in your Colab environment, ready to run.

---

## Hardware Requirements

- **GPU required** for the **MobileNetV4** and **SwinBase** training scripts, as well as the **Data Augmentation online showcase**. A GPU with **at least 12 GB of VRAM** is needed to avoid out-of-memory (OOM) errors. The researchers used the **NVIDIA L4 GPU** available through Google Colab Pro.
- **CPU only** is sufficient for all other sections of the notebook.
