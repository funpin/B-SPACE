import { useEffect, useRef, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { useVoiceStore } from '../../../stores/voiceStore';
import { AudioManager } from '../../../audio/AudioManager';
import { platformSupportsOutputSelection } from '../../../audio/outputRouter';
import { useAudioDevices } from '../../../hooks/useAudioDevices';
import { Button } from '../../ui/Button';
import { Icon } from '../../ui/Icon';
import { SectionShell, DropdownItem } from './_shared/SettingsPickerPrimitives';

export function AudioOutputSection() {
  // Hard gate: if the engine can point neither an AudioContext nor a media
  // element at a device (iOS Safari), hide the entire section. Users adjust
  // output via OS controls (Bluetooth menu, etc.). The answer comes from the
  // prototypes and cannot change within a page lifetime, so hook order
  // downstream is stable.
  if (!platformSupportsOutputSelection()) return null;
  return <AudioOutputSectionInner />;
}

function AudioOutputSectionInner() {
  const { t } = useTranslation(['settings', 'common']);
  const outputDeviceId = useVoiceStore((s) => s.outputDeviceId);
  const setOutputDevice = useVoiceStore((s) => s.setOutputDevice);
  const outputVolume = useVoiceStore((s) => s.outputVolume);
  const setOutputVolume = useVoiceStore((s) => s.setOutputVolume);
  const { permState, outputs, outputLabels, requestPermission } = useAudioDevices();

  const [listOpen, setListOpen] = useState(false);
  const dropdownRef = useRef<HTMLDivElement>(null);

  // Click-outside-to-close. Listens for both mousedown and touchstart so the
  // popover dismisses with a single tap on touch devices (iOS Safari does not
  // synthesize mousedown reliably from touch).
  useEffect(() => {
    if (!listOpen) return;
    const onPointerDown = (e: MouseEvent | TouchEvent) => {
      if (dropdownRef.current && !dropdownRef.current.contains(e.target as Node)) {
        setListOpen(false);
      }
    };
    document.addEventListener('mousedown', onPointerDown);
    document.addEventListener('touchstart', onPointerDown, { passive: true });
    return () => {
      document.removeEventListener('mousedown', onPointerDown);
      document.removeEventListener('touchstart', onPointerDown);
    };
  }, [listOpen]);

  if (permState === 'unknown') {
    return (
      <SectionShell title={t('voice.output.title')}>
        <div className="text-sm text-txt-tertiary">{t('voice.output.checkingAccess')}</div>
      </SectionShell>
    );
  }

  // Output-device labels are gated behind microphone permission. If permission
  // is not granted we can still let the user adjust output volume + test the
  // current default, but the picker is hidden.
  const showPicker = permState === 'granted';
  const systemDefaultLabel = t('voice.output.device.systemDefault');
  const selectedLabel = outputDeviceId === 'default'
    ? systemDefaultLabel
    : outputLabels.get(outputDeviceId) ?? systemDefaultLabel;

  const handleSelect = (id: string) => {
    // First, and straight from the click: an engine may accept a choice of
    // speaker only inside the gesture that made it (outputRouter.ts).
    AudioManager.getInstance().setOutputDevice(id).catch(() => {});
    setOutputDevice(id);
    setListOpen(false);
  };

  const handleTestTone = async () => {
    try { await AudioManager.getInstance().playTestTone(); } catch { /* best-effort */ }
  };

  return (
    <SectionShell title={t('voice.output.title')}>
      <div className="space-y-3">
        {showPicker ? (
          <div ref={dropdownRef}>
            <button
              type="button"
              onClick={() => setListOpen((v) => !v)}
              className="w-full h-[38px] px-3 flex items-center justify-between rounded-lg bg-surface-input shadow-[inset_0_0_0_1px_var(--glass-border)] hover:bg-interactive-hover transition-colors duration-fast"
            >
              <span className="text-compact text-txt-primary truncate text-left">{selectedLabel}</span>
              <Icon
                name="chevron-right"
                size="sm"
                className={`text-txt-tertiary ml-2 transition-transform duration-base ease-out ${listOpen ? 'rotate-90' : ''}`}
              />
            </button>
            {listOpen && (
              <div className="mt-1 rounded-lg bg-surface-input border border-border-soft py-1 max-h-64 overflow-y-auto">
                <DropdownItem label={systemDefaultLabel} active={outputDeviceId === 'default'} onClick={() => handleSelect('default')} />
                {outputs.filter(d => d.deviceId !== 'default').map((d) => (
                  <DropdownItem
                    key={d.deviceId}
                    label={outputLabels.get(d.deviceId) ?? d.deviceId}
                    active={outputDeviceId === d.deviceId}
                    onClick={() => handleSelect(d.deviceId)}
                  />
                ))}
              </div>
            )}
          </div>
        ) : (
          <div className="space-y-2">
            <div className="text-xs text-txt-tertiary">
              {t('voice.output.permissionPrompt.description')}
            </div>
            <Button variant="primary" onClick={() => { requestPermission().catch(() => {}); }}>
              {t('voice.output.permissionPrompt.enable')}
            </Button>
          </div>
        )}

        <div>
          <div className="flex items-center justify-between mb-1.5">
            <div className="text-compact font-medium text-txt-primary">{t('voice.output.volume.label')}</div>
            <div className="text-xs text-txt-tertiary tabular-nums">{t('common:units.percent', { value: outputVolume })}</div>
          </div>
          <input
            type="range"
            min={0}
            max={200}
            value={outputVolume}
            onChange={(e) => setOutputVolume(Number(e.target.value))}
            className="w-full h-1.5 rounded-full appearance-none cursor-pointer bg-interactive-muted [&::-webkit-slider-thumb]:appearance-none [&::-webkit-slider-thumb]:w-3 [&::-webkit-slider-thumb]:h-3 [&::-webkit-slider-thumb]:rounded-full [&::-webkit-slider-thumb]:bg-txt-primary [&::-webkit-slider-thumb]:shadow-md"
            style={{
              background: `linear-gradient(to right, rgb(var(--accent-tone)) 0%, rgb(var(--accent-tone)) ${outputVolume / 2}%, rgb(var(--interactive-muted)) ${outputVolume / 2}%, rgb(var(--interactive-muted)) 100%)`,
            }}
          />
        </div>

        <Button variant="secondary" icon="volume-1" fullWidth onClick={handleTestTone}>
          {t('voice.output.testSound')}
        </Button>
      </div>
    </SectionShell>
  );
}
