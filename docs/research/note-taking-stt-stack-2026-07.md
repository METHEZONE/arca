# ARCA Note-Taking STT Stack Research

Date: 2026-07-03

## Target

Build a note-taking app that handles English and Korean accurately, separates speakers, and turns recordings into notes, decisions, action items, and long-term memory.

## Recommended Stack

Use ARCA as the product shell and memory pipeline.

1. Primary STT: OpenAI `gpt-4o-transcribe-diarize`
   - Strong fit for English/Korean.
   - Returns diarized JSON with speaker segments.
   - Supports known speaker reference clips for up to four speakers.
   - Current limitation: file upload limit is 25 MB, so long recordings need chunking or fallback.

2. Fallback STT: ElevenLabs Scribe v2
   - Supports 90+ languages, word-level timestamps, and speaker diarization.
   - Useful as an API fallback and for larger-file experiments.

3. Local/open-source lane: WhisperX + pyannote.audio
   - WhisperX combines fast ASR, word-level timestamps, VAD, and pyannote diarization.
   - pyannote.audio is the speaker-diarization core and can run locally after model access setup.
   - Keep this as a Python worker, not inside the Next.js request path.

4. Product/UI inspiration: Meetily and TranscriptionSuite
   - Meetily is the strongest open-source meeting-note product reference.
   - TranscriptionSuite is a useful local audio-notebook reference, but GPL-3.0 means avoid copying code into ARCA unless ARCA licensing is deliberately changed.

## GitHub Snapshot

Queried GitHub repository metadata on 2026-07-03.

| Repo | Role | Stars | License | Latest push observed |
|---|---|---:|---|---|
| `openai/whisper` | Base ASR reference | 104068 | MIT | 2026-04-15 |
| `ggml-org/whisper.cpp` | Local/native Whisper runtime | 51240 | MIT | 2026-07-01 |
| `SYSTRAN/faster-whisper` | Fast Whisper backend | 23992 | MIT | 2025-11-19 |
| `m-bain/whisperX` | ASR + alignment + diarization | 22857 | BSD-2-Clause | 2026-06-26 |
| `NVIDIA/NeMo` | Research/enterprise speech toolkit | 17700 | Apache-2.0 | 2026-07-02 |
| `Zackriya-Solutions/meetily` | Meeting-note app reference | 13655 | MIT | 2026-06-05 |
| `pyannote/pyannote-audio` | Speaker diarization core | 10213 | MIT | 2026-07-02 |
| `homelab-00/TranscriptionSuite` | Local audio notebook reference | 532 | GPL-3.0 | 2026-06-28 |

## Architecture

```text
audio upload / hardware ingest
  -> transcription router
     -> OpenAI diarized STT
     -> ElevenLabs Scribe fallback
     -> future local worker: WhisperX + pyannote
  -> transcript normalization
  -> Claude/OpenAI analysis
  -> ARCA memory JSON
  -> Obsidian / Notion / Slack
```

## Implementation Notes

- Keep one internal transcript shape: `speaker`, `speakerLabel`, `text`, `startMs`, `endMs`.
- Use provider fallback only in `TRANSCRIPTION_PROVIDER=auto`.
- If `TRANSCRIPTION_PROVIDER=openai` or `elevenlabs`, fail clearly instead of silently switching providers.
- Add chunking before relying on OpenAI for long meetings because the API upload limit is 25 MB.
- Do not copy GPL-3.0 code from TranscriptionSuite into ARCA.

## Sources

- OpenAI Speech to Text guide: https://developers.openai.com/api/docs/guides/speech-to-text
- ElevenLabs Speech to Text docs: https://elevenlabs.io/docs/overview/capabilities/speech-to-text
- WhisperX: https://github.com/m-bain/whisperX
- pyannote.audio: https://github.com/pyannote/pyannote-audio
- faster-whisper: https://github.com/SYSTRAN/faster-whisper
- whisper.cpp: https://github.com/ggml-org/whisper.cpp
- Meetily: https://github.com/Zackriya-Solutions/meetily
- TranscriptionSuite: https://github.com/homelab-00/TranscriptionSuite
