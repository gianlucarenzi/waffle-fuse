// Waffle ModPlayer – playback engine (see modengine.h)

#include "modengine.h"

#include <QMutexLocker>
#include <QTimer>
#include <algorithm>
#include <cmath>

#include <mikmod.h>

ModEngine::ModEngine(QObject *parent) : QObject(parent)
{
}

ModEngine::~ModEngine()
{
    shutdown();
}

bool ModEngine::initLibrary()
{
    if (m_libReady) return true;
    // As WaffleCopyPRO: software mixer, interpolation, 16-bit stereo at 44.1 kHz
    md_mode = DMODE_SOFT_MUSIC | DMODE_INTERP | DMODE_STEREO | DMODE_16BITS;
    md_mixfreq = 44100;
    MikMod_RegisterAllLoaders();
    if (m_muted) MikMod_RegisterDriver(&drv_nos);
    else MikMod_RegisterAllDrivers();
    // Only real audio outputs, then "nosound" (the VU meters still move): the
    // autodetection of libmikmod would fall back to a disk writer, a music.wav
    // in the current directory
    static const char *const outputs[] = {"pulseaudio", "alsa", "oss", "osx", "ds", "winmm", "nosound"};
    bool ready = false;
    for (const char *alias : outputs)
    {
        const int device = MikMod_DriverFromAlias(const_cast<char *>(alias));
        if (device <= 0) continue;
        md_device = UWORD(device);
        if (MikMod_Init(const_cast<char *>("")) == 0)
        {
            ready = true;
            break;
        }
    }
    if (!ready)
    {
        emit failed(QString("No audio output: %1").arg(MikMod_strerror(MikMod_errno)));
        return false;
    }
    m_driver = md_driver && md_driver->Name ? QString::fromLatin1(md_driver->Name) : QString();
    m_timer = new QTimer(this);
    m_timer->setTimerType(Qt::PreciseTimer);
    m_timer->setInterval(10);
    connect(m_timer, &QTimer::timeout, this, &ModEngine::update);
    m_libReady = true;
    return true;
}

void ModEngine::freeModule()
{
    if (!m_module) return;
    Player_Stop();
    Player_Free(m_module);
    m_module = nullptr;
}

void ModEngine::load(const QByteArray &data, const QString &name)
{
    if (!initLibrary()) return;
    if (m_timer) m_timer->stop();
    freeModule();
    // From memory: the window reads the file, so any path (Unicode on Windows,
    // a floppy mounted through FUSE) works the same
    m_module = Player_LoadMem(data.constData(), int(data.size()), 64, 0);
    if (!m_module)
    {
        emit failed(QString("%1: %2").arg(name, MikMod_strerror(MikMod_errno)));
        return;
    }
    m_module->wrap = 0;     // play the song once: no restart at the end
    m_module->loop = 0;     // and no endless loops inside it
    m_module->fadeout = 1;

    ModInfo info;
    info.title = QString::fromLatin1(m_module->songname ? m_module->songname : "").trimmed();
    info.type = QString::fromLatin1(m_module->modtype ? m_module->modtype : "").trimmed();
    info.channels = m_module->numchn;
    info.positions = m_module->numpos;
    info.driver = m_driver;
    {
        QMutexLocker lock(&m_mutex);
        m_state = ModState();
        m_state.levels.fill(0.0f, m_module->numchn);
        m_state.positions = m_module->numpos;
    }
    m_data = data;
    emit loaded(info);
}

void ModEngine::play()
{
    if (!m_module) return;
    ModState s = state();
    if (s.paused)
    {
        togglePause();
        return;
    }
    if (s.playing) return;
    if (s.finished)
    {
        // From the beginning: a fresh copy of the module
        Player_Stop();
        Player_Free(m_module);
        m_module = Player_LoadMem(m_data.constData(), int(m_data.size()), 64, 0);
        if (!m_module) return;
        m_module->wrap = 0;
        m_module->loop = 0;
        m_module->fadeout = 1;
    }
    Player_Start(m_module);
    {
        QMutexLocker lock(&m_mutex);
        m_state.playing = true;
        m_state.paused = false;
        m_state.finished = false;
    }
    m_timer->start();
}

void ModEngine::togglePause()
{
    if (!m_module || !Player_Active()) return;
    Player_TogglePause();
    QMutexLocker lock(&m_mutex);
    m_state.paused = Player_Paused();
    m_state.playing = !m_state.paused;
}

void ModEngine::stop()
{
    if (!m_module) return;
    if (m_timer) m_timer->stop();
    Player_Stop();
    QMutexLocker lock(&m_mutex);
    m_state.playing = false;
    m_state.paused = false;
    m_state.finished = true;      // Play starts again from the beginning
    m_state.position = 0;
    m_state.seconds = 0;
    m_state.levels.fill(0.0f);
}

void ModEngine::skip(int positions)
{
    if (!m_module || !Player_Active()) return;
    if (positions > 0) for (int i = 0; i < positions; ++i) Player_NextPosition();
    else for (int i = 0; i < -positions; ++i) Player_PrevPosition();
}

void ModEngine::shutdown()
{
    if (m_timer) m_timer->stop();
    freeModule();
    if (m_libReady)
    {
        MikMod_Exit();
        m_libReady = false;
    }
}

void ModEngine::update()
{
    if (!m_module) return;
    if (Player_Paused()) return;
    if (!Player_Active())
    {
        m_timer->stop();
        publish(true);
        emit finished();
        return;
    }
    if (m_muted)
    {
        // The nosound driver mixes a 32 KB buffer per update and returns at
        // once: one update per buffer length keeps the song in real time
        const double bufferMs = 32768.0 * 1000.0 / (md_mixfreq * 4.0);
        if (m_sinceUpdate.isValid() && m_sinceUpdate.elapsed() < bufferMs) return;
        m_sinceUpdate.start();
    }
    MikMod_Update();
    publish();
}

void ModEngine::publish(bool finishedNow)
{
    QVector<float> levels(m_module->numchn, 0.0f);
    if (!finishedNow)
    {
        for (int ch = 0; ch < m_module->numchn; ++ch)
        {
            int voice = Player_GetChannelVoice(UBYTE(ch));
            if (voice < 0) continue;
            // Amplitude of what the voice is playing now (0..65535), a little
            // compressed so quiet instruments still move their bar
            float v = float(Voice_RealVolume(SBYTE(voice))) / 65535.0f;
            levels[ch] = std::min(1.0f, std::pow(std::max(0.0f, v), 0.7f));
        }
    }
    QMutexLocker lock(&m_mutex);
    m_state.levels = levels;
    m_state.position = m_module->sngpos;
    m_state.positions = m_module->numpos;
    m_state.seconds = m_module->sngtime / 1024.0;
    if (finishedNow)
    {
        m_state.playing = false;
        m_state.paused = false;
        m_state.finished = true;
    }
}

ModState ModEngine::state() const
{
    QMutexLocker lock(&m_mutex);
    return m_state;
}
