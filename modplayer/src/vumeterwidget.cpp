// Waffle ModPlayer – VU meters (see vumeterwidget.h)

#include "vumeterwidget.h"

#include <QLinearGradient>
#include <QPainter>
#include <algorithm>

namespace {
const int kBarSpacing = 4;
const int kMaxBarWidth = 48;
const float kDecay = 0.04f;        // per tick (~60 Hz): from full to zero in ~0.4 s
const float kPeakDecay = 0.008f;   // peaks fall slower, ~2 s
}

VuMeterWidget::VuMeterWidget(QWidget *parent) : QWidget(parent)
{
    setAttribute(Qt::WA_OpaquePaintEvent, false);
    setMinimumHeight(120);
    m_decayTimer.setTimerType(Qt::PreciseTimer);
    m_decayTimer.setInterval(16);
    connect(&m_decayTimer, &QTimer::timeout, this, &VuMeterWidget::decayLevels);
    m_decayTimer.start();
}

void VuMeterWidget::setChannels(int channels)
{
    m_currentLevels.fill(0.0f, std::max(0, channels));
    m_peakLevels.fill(0.0f, std::max(0, channels));
    update();
}

void VuMeterWidget::setAudioLevels(const QVector<float> &levels)
{
    if (levels.isEmpty()) return;      // nothing new: the bars just fall
    if (m_currentLevels.size() != levels.size()) setChannels(int(levels.size()));
    for (int i = 0; i < levels.size(); ++i)
    {
        float level = std::clamp(levels[i], 0.0f, 1.0f);
        // Up at once, down smoothly (decayLevels)
        m_currentLevels[i] = std::max(m_currentLevels[i], level);
        m_peakLevels[i] = std::max(m_peakLevels[i], level);
    }
    update();
}

void VuMeterWidget::resetLevels()
{
    m_currentLevels.fill(0.0f);
    m_peakLevels.fill(0.0f);
    update();
}

void VuMeterWidget::paintEvent(QPaintEvent *)
{
    QPainter painter(this);
    const int n = int(m_currentLevels.size());
    if (n == 0) return;

    int barWidth = std::min(kMaxBarWidth, (width() - (n + 1) * kBarSpacing) / n);
    if (barWidth <= 0) return;
    const int total = n * barWidth + (n + 1) * kBarSpacing;
    const int left = (width() - total) / 2;
    const int h = height();

    // The same gradient as WaffleCopyPRO, over the whole height of the bar
    QLinearGradient gradient(0, h, 0, 0);
    gradient.setColorAt(0.0, m_green);
    gradient.setColorAt(0.25, m_yellow);
    gradient.setColorAt(0.5, m_orange);
    gradient.setColorAt(0.75, m_red);

    for (int i = 0; i < n; ++i)
    {
        const int x = left + kBarSpacing + i * (barWidth + kBarSpacing);
        // Dim background of the bar, then the lit part
        painter.fillRect(x, 0, barWidth, h, QColor(255, 255, 255, 18));
        const int barHeight = int(m_currentLevels[i] * h);
        painter.fillRect(x, h - barHeight, barWidth, barHeight, gradient);
        // Peak marker
        if (m_peakLevels[i] > 0.01f)
        {
            const int y = std::min(h - 2, int(h - m_peakLevels[i] * h));
            painter.fillRect(x, y, barWidth, 2, Qt::white);
        }
    }
}

void VuMeterWidget::decayLevels()
{
    bool changed = false;
    for (int i = 0; i < m_currentLevels.size(); ++i)
    {
        if (m_currentLevels[i] > 0.0f)
        {
            m_currentLevels[i] = std::max(0.0f, m_currentLevels[i] - kDecay);
            changed = true;
        }
        if (m_peakLevels[i] > 0.0f)
        {
            m_peakLevels[i] = std::max(0.0f, m_peakLevels[i] - kPeakDecay);
            changed = true;
        }
    }
    if (changed) update();
}
