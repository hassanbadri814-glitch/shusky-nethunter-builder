#!/usr/bin/env bash
# Apply narrowly scoped RTL8187 changes so it uses only symbols in the
# already-published Android GKI virtual_device ABI, without changing the
# Pixel ABI file or weakening strict KMI enforcement.
set -Eeuo pipefail
ROOT="${1:?Android kernel source root required}"
REPORT="${2:?report path required}"
DEV="$ROOT/drivers/net/wireless/realtek/rtl818x/rtl8187/dev.c"
RFKILL_C="$ROOT/drivers/net/wireless/realtek/rtl818x/rtl8187/rfkill.c"
RFKILL_H="$ROOT/drivers/net/wireless/realtek/rtl818x/rtl8187/rfkill.h"
MAC80211="$ROOT/net/mac80211/main.c"
CFG80211="$ROOT/net/wireless/core.c"
for f in "$DEV" "$RFKILL_C" "$RFKILL_H" "$MAC80211" "$CFG80211"; do
  test -s "$f" || { echo "ERROR: required source missing: $f" >&2; exit 1; }
done

python3 - "$DEV" "$RFKILL_C" "$RFKILL_H" "$MAC80211" "$CFG80211" "$REPORT" <<'PY'
from pathlib import Path
import re, sys

dev_path, rfkill_c_path, rfkill_h_path, mac80211_path, cfg80211_path, report_path = map(Path, sys.argv[1:])
dev = dev_path.read_text()
rfkill_c = rfkill_c_path.read_text()
rfkill_h = rfkill_h_path.read_text()
mac80211 = mac80211_path.read_text()
cfg80211 = cfg80211_path.read_text()

def replace_once(text, old, new, label):
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"ERROR: expected exactly one {label} source pattern; found {count}")
    return text.replace(old, new, 1)

# The callback already has an IRQ-save lock variable 'f'. Preserve skb_unlink()
# semantics using its in-header implementation, with the same queue lock.
old_callback = (
    "\tif (usb_submit_urb(urb, GFP_ATOMIC)) {\n"
    "\t\tusb_unanchor_urb(urb);\n"
    "\t\tskb_unlink(skb, &priv->rx_queue);\n"
    "\t\tdev_kfree_skb_irq(skb);\n"
    "\t}"
)
new_callback = (
    "\tif (usb_submit_urb(urb, GFP_ATOMIC)) {\n"
    "\t\tusb_unanchor_urb(urb);\n"
    "\t\tspin_lock_irqsave(&priv->rx_queue.lock, f);\n"
    "\t\t__skb_unlink(skb, &priv->rx_queue);\n"
    "\t\tspin_unlock_irqrestore(&priv->rx_queue.lock, f);\n"
    "\t\tdev_kfree_skb_irq(skb);\n"
    "\t}"
)
dev = replace_once(dev, old_callback, new_callback, "RX callback skb unlink")

# The init path has no existing IRQ flags variable; add one and use the
# same locked inline unlink operation on URB submission failure.
old_decl = (
    "\tstruct rtl8187_rx_info *info;\n"
    "\tint ret = 0;"
)
new_decl = (
    "\tstruct rtl8187_rx_info *info;\n"
    "\tunsigned long flags;\n"
    "\tint ret = 0;"
)
dev = replace_once(dev, old_decl, new_decl, "RTL8187 URB-init flags declaration")
old_init = (
    "\t\tif (ret) {\n"
    "\t\t\tskb_unlink(skb, &priv->rx_queue);\n"
    "\t\t\tusb_unanchor_urb(entry);"
)
new_init = (
    "\t\tif (ret) {\n"
    "\t\t\tspin_lock_irqsave(&priv->rx_queue.lock, flags);\n"
    "\t\t\t__skb_unlink(skb, &priv->rx_queue);\n"
    "\t\t\tspin_unlock_irqrestore(&priv->rx_queue.lock, flags);\n"
    "\t\t\tusb_unanchor_urb(entry);"
)
dev = replace_once(dev, old_init, new_init, "RTL8187 URB-init skb unlink")

# rfkill polling is stopped by ieee80211_unregister_hw() -> wiphy_unregister()
# -> rfkill_unregister(). Remove the driver's redundant inline wrapper, which
# otherwise creates a direct import of rfkill_pause_polling outside Pixel KMI.
old_exit_call = "\trtl8187_rfkill_exit(dev);\n"
dev = replace_once(dev, old_exit_call, "", "RTL8187 rfkill exit call")
old_exit_fn = (
    "void rtl8187_rfkill_exit(struct ieee80211_hw *hw)\n"
    "{\n"
    "\twiphy_rfkill_stop_polling(hw->wiphy);\n"
    "}\n"
)
rfkill_c = replace_once(rfkill_c, old_exit_fn, "", "RTL8187 rfkill exit function")
old_decl_fn = "void rtl8187_rfkill_exit(struct ieee80211_hw *hw);\n"
rfkill_h = replace_once(rfkill_h, old_decl_fn, "", "RTL8187 rfkill exit declaration")

# Prove the lifecycle that now owns polling teardown.
unreg_start = mac80211.find("void ieee80211_unregister_hw")
if unreg_start < 0 or "wiphy_unregister(" not in mac80211[unreg_start:unreg_start + 10000]:
    raise SystemExit("ERROR: ieee80211_unregister_hw() does not visibly call wiphy_unregister()")
wiphy_start = cfg80211.find("void wiphy_unregister")
if wiphy_start < 0 or "rfkill_unregister(rdev->wiphy.rfkill)" not in cfg80211[wiphy_start:wiphy_start + 5000]:
    raise SystemExit("ERROR: wiphy_unregister() does not visibly unregister rfkill")

if re.search(r"(?<!_)skb_unlink\s*\(", dev) or "rfkill_pause_polling" in dev + rfkill_c + rfkill_h:
    raise SystemExit("ERROR: protected skb_unlink/rfkill_pause_polling reference remains")
if dev.count("__skb_unlink(skb, &priv->rx_queue)") != 3:
    raise SystemExit("ERROR: expected original RX dequeue plus two locked __skb_unlink sites")

dev_path.write_text(dev)
rfkill_c_path.write_text(rfkill_c)
rfkill_h_path.write_text(rfkill_h)

Path(report_path).write_text(
    "RTL8187 KMI source compatibility patch: PASS\n"
    "skb_unlink imports removed: both sites use __skb_unlink under the original queue spinlock\n"
    "rfkill_pause_polling import removed: redundant driver stop removed; unregister lifecycle verified\n"
    "ieee80211_unregister_hw -> wiphy_unregister: verified\n"
    "wiphy_unregister -> rfkill_unregister: verified\n"
    "No Pixel KMI source file changed; no kernel symbol export was added.\n"
)
print(Path(report_path).read_text(), end="")
PY
