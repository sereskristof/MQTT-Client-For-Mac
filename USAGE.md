# MQTT Client For Mac – Quick start

**MQTT Client For Mac** is a simple MQTT client for macOS. Connect to a broker, see every topic in a tree, and publish messages.

## 1. Connect to your broker

1. Start the app. On the first launch the **Connections** window opens by itself.
   (Later: toolbar **Connections…**.)
2. Click **Add connection**.
   Not sure where your broker is? Click **Find brokers on the network** instead.
3. Fill in:
   - **Host**: for example `192.168.1.10` or `broker.example.com`
   - **Port**: `1883` for plain connections, `8883` for TLS (it switches automatically with the **Protocol** setting)
   - **User name / Password**: only if your broker needs them
4. Click **Connect**.

The dot in the bottom bar turns green when you are connected.

## 2. Look at your topics

- Topics appear in the tree on the left. Click one to see its value.
- A row flashes when a new value arrives. A pin means the message is *retained*.
- The tabs on the right:
  - **Value**: the latest message (Auto, Text, JSON or Hex view)
  - **Changes**: what changed compared to the previous message
  - **Chart**: numeric values over time
  - **History**: the last 200 messages of this topic
- Use the search box to filter topics and values.

Nothing shows up? See [Troubleshooting](#troubleshooting).

## 3. Publish a message

Use the **Publish** panel at the bottom:

1. Type the **Topic** (clicking a topic in the tree fills it in for you).
2. Choose **QoS** and, if you want, **Retain**.
3. Write the message and click **Publish** (`⌘↩`).

Handy: **Format JSON** tidies your JSON, and **Recent** brings back earlier messages.
You can drag the line above the panel to make it bigger or smaller.

## 4. Choose what you subscribe to

Click **Subscriptions** in the toolbar (while connected) to add or remove topic filters.

| Filter | Meaning |
| --- | --- |
| `#` | everything (except `$SYS`) |
| `home/#` | everything below `home` |
| `sensors/+/temperature` | one level can be anything |
| `$SYS/#` | broker statistics |

The same list is in your connection settings under **Subscriptions**.

## 5. Secure connection (TLS)

In the connection settings choose **mqtts://**. Then, if your broker needs it:

- drop your **CA certificate** (`.pem`, `.crt`, `.cer`) into the CA box,
- drop your **client certificate** (`.p12`) into the client box and enter its password.

Click **Test connection** at the bottom. It shows each step and tells you what is wrong,
for example a wrong host name or an untrusted CA, and often offers a one-click fix.

## 6. Other things you can do

| I want to… | Do this |
| --- | --- |
| Delete a retained message | Select the topic, click the pin-slash icon in the header |
| Stop the flow for a moment | **Pause** in the toolbar |
| Start with an empty tree | **Clear tree** in the toolbar |
| Save the tree with its values | **Export** (JSON file) |
| Copy a topic or value | The copy icons in the header |

Shortcuts: `⌘R` connect, `⌘D` disconnect, `⌘↩` publish.

## Troubleshooting

- **Connected, but the tree is empty**
  The broker may not allow this user to read the topics. Check the broker's access rules (ACL)
  and your **Subscriptions**. A banner appears if the broker refuses a subscription.
- **Cannot connect**
  Open the connection settings and click **Test connection**. It explains the problem.
- **A message shows a lower QoS than I published**
  A message arrives with the lower of the published QoS and the **Subscription QoS**.
  Set the subscription QoS to `2`.
- **The connection dropped**
  The app reconnects automatically. **Disconnect** stops it.

## Good to know

- Passwords and certificates are stored in the macOS Keychain.
- The app only talks to the broker you set up. **Find brokers on the network** scans your local
  network for MQTT ports. Use it only on networks you are allowed to scan.
