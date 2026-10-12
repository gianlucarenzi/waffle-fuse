// Waffle ModPlayer – sine scroller (see sinescroller.h)

#include "sinescroller.h"

#include <QFontMetrics>
#include <QPainter>
#include <cmath>

SineScroller::SineScroller(QWidget *parent) : QWidget(parent)
{
    setMinimumHeight(40);
    m_timer.setTimerType(Qt::PreciseTimer);
    m_timer.setInterval(16);
    connect(&m_timer, &QTimer::timeout, this, &SineScroller::step);
}

void SineScroller::setText(const QString &text)
{
    m_text = text;
    m_offset = -width();     // the text comes in from the right
    update();
}

void SineScroller::setRunning(bool running)
{
    if (running) m_timer.start();
    else m_timer.stop();
}

void SineScroller::step()
{
    m_offset += 2.0;
    m_phase += 0.12;
    const int textWidth = QFontMetrics(font()).horizontalAdvance(m_text);
    if (m_offset > textWidth) m_offset = -width();
    update();
}

void SineScroller::paintEvent(QPaintEvent *)
{
    if (m_text.isEmpty()) return;
    QPainter painter(this);
    painter.setFont(font());
    const QFontMetrics fm(font());
    const double amplitude = std::max(2.0, (height() - fm.height()) / 2.0);
    const int baseY = (height() + fm.ascent() - fm.descent()) / 2;

    double x = -m_offset;
    for (int i = 0; i < m_text.size() && x < width(); ++i)
    {
        const QChar ch = m_text.at(i);
        const int advance = fm.horizontalAdvance(ch);
        if (x + advance >= 0)
        {
            const double wave = std::sin(x * 0.025 + m_phase);
            // Copper colours: the hue follows the position on the screen
            const int hue = int(std::fmod(x * 0.6 + m_phase * 40.0, 360.0) + 360) % 360;
            painter.setPen(QColor::fromHsv(hue, 200, 255));
            painter.drawText(QPointF(x, baseY + wave * amplitude), QString(ch));
        }
        x += advance;
    }
}
