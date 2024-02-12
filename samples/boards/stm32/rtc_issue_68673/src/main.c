#include <stddef.h>
#include <zephyr/kernel.h>
#include <zephyr/sys/util.h>
#include <zephyr/types.h>

#include <zephyr/drivers/counter.h>
#include <zephyr/sys/timeutil.h>
#include <zephyr/device.h>
#include <time.h>

static const struct device *mDevice = DEVICE_DT_GET(DT_INST(0, st_stm32_rtc));
static struct counter_alarm_cfg mAlarm;

void callback(const struct device* dev, uint8_t chan, uint32_t ticks, void* data)
{
	printk("Hi from callback\n");
}

int main(void)
{
	printk("Start counter\n");

	if (!device_is_ready(mDevice)) {
		printk("Device not ready\n");
		return 0;
	}
	counter_start(mDevice);

	mAlarm.flags = 0;
	mAlarm.ticks = 3; // Callback should come at 3 seconds
	mAlarm.callback = callback;
	mAlarm.user_data = &mAlarm;

	int err = counter_set_channel_alarm(mDevice, 0, &mAlarm);
	if(err == 0) {
		printk("Set alarm OK\n");
	} else {
		printk("Failed to set alarm\n");
	}

	while (1) {
		k_sleep(K_SECONDS(5));
	}

	return 0;
}
