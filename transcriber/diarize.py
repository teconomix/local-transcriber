"""Sprechertrennung mit pyannote speaker-diarization-community-1 auf MPS.
Liefert exklusive Segmente (je Zeitpunkt höchstens ein Sprecher) und je Cluster eine Stimmeinbettung."""
from collections import Counter

_PIPE = None


def _pipeline():
    global _PIPE
    if _PIPE is None:
        import torch
        from pyannote.audio import Pipeline
        # Vom Installer mitgeliefert (CC-BY-4.0, kein Hugging-Face-Konto nötig), sonst aus dem HF-Cache.
        from . import config
        local = config.DATA / "models" / "speaker-diarization-community-1"
        _PIPE = Pipeline.from_pretrained(str(local) if (local / "config.yaml").exists()
                                         else "pyannote/speaker-diarization-community-1")
        _PIPE.to(torch.device("mps" if torch.backends.mps.is_available() else "cpu"))
    return _PIPE


def diarize(wav, min_speakers=2, max_speakers=6, num_speakers=None):
    import numpy as np
    import soundfile as sf
    import torch
    x, sr = sf.read(str(wav), dtype="float32")
    kw = {"num_speakers": num_speakers} if num_speakers else {"min_speakers": min_speakers, "max_speakers": max_speakers}
    o = _pipeline()({"waveform": torch.from_numpy(x).unsqueeze(0), "sample_rate": sr}, **kw)
    labels = list(o.speaker_diarization.labels())
    emb = np.asarray(o.speaker_embeddings)
    segs = [{"start": round(s.start, 3), "end": round(s.end, 3), "speaker": spk}
            for s, _, spk in o.exclusive_speaker_diarization.itertracks(yield_label=True)]
    dur = Counter()
    for s in segs:
        dur[s["speaker"]] += s["end"] - s["start"]
    clusters = [{"label": l, "speech_s": round(dur[l], 1), "embedding": emb[i]} for i, l in enumerate(labels)
                if i < len(emb) and not np.isnan(emb[i]).any()]
    return segs, clusters
