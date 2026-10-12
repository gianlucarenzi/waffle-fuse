// Waffle ModPlayer – VU meters, one bar per channel of the module.
// From the VuMeterWidget of WaffleCopyPRO (waffleCopyPRO-Universal): the same
// green-yellow-orange-red bars that fall back smoothly, here with a peak
// marker and bars that fit the width of the window for 4 to 32 channels.

#pragma once

#include <QColor>
#include <QTimer>
#include <QVector>
#include <QWidget>

class VuMeterWidget : public QWidget
{
    Q_OBJECT

public:
    explicit VuMeterWidget(QWidget *parent = nullptr);

public slots:
    void setAudioLevels(const QVector<float> &levels);
    void setChannels(int channels);
    void resetLevels();

protected:
    void paintEvent(QPaintEvent *event) override;

private:
    void decayLevels();

    QVector<float> m_currentLevels;
    QVector<float> m_peakLevels;
    QTimer m_decayTimer;
    QColor m_red{255, 0, 0};
    QColor m_orange{255, 165, 0};
    QColor m_yellow{255, 255, 0};
    QColor m_green{0, 255, 0};
};
