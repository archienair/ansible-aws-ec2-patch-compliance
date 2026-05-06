# Ansible AWS EC2 Patch Automation & Compliance Lab

A hands-on lab simulating a real-world structured monthly Linux patch cycle across DEV, QA, and PROD environments on AWS EC2 — using Ansible for automation, SSM Agent for agentless patching, and CIS benchmark hardening roles.

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Pre-requisites](#pre-requisites)
- [Environment Setup](#environment-setup)
- [Project Structure](#project-structure)
- [How the Patch Cycle Works](#how-the-patch-cycle-works)
- [Ansible Roles](#ansible-roles)
- [Running the Playbooks](#running-the-playbooks)
- [Post-Patch Health Checks](#post-patch-health-checks)
- [CIS Hardening](#cis-hardening)
- [SSM Patching (No Public IP)](#ssm-patching-no-public-ip)
- [Sample Output](#sample-output)
- [Lessons Learned](#lessons-learned)

---

## Overview

In production environments, you never patch all servers at once. A bad kernel update or package conflict can break applications. The industry standard is a **staged patch cycle**:

```
DEV → QA → PROD
```

Each stage has a one-week gap. If something breaks in DEV, it gets fixed before it ever reaches PROD.

This lab builds that exact workflow using:

- **AWS EC2** — RHEL 9 and Amazon Linux 2023 instances across 3 environments
- **Ansible** — automated patching, health checks, and hardening
- **AWS SSM Agent** — patch private instances without SSH or a public IP
- **CIS Benchmark roles** — applied post-patch to maintain compliance

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                        AWS VPC                          │
│                                                         │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
│  │  DEV Subnet  │  │  QA Subnet   │  │ PROD Subnet  │  │
│  │  (Public)    │  │  (Public)    │  │  (Private)   │  │
│  │              │  │              │  │              │  │
│  │ ec2-dev-01   │  │ ec2-qa-01    │  │ ec2-prod-01  │  │
│  │ RHEL 9       │  │ RHEL 9       │  │ RHEL 9       │  │
│  │              │  │              │  │              │  │
│  │ ec2-dev-02   │  │ ec2-qa-02    │  │ ec2-prod-02  │  │
│  │ Amazon Linux │  │ Amazon Linux │  │ Amazon Linux │  │
│  │ 2023         │  │ 2023         │  │ 2023         │  │
│  └──────────────┘  └──────────────┘  └──────────────┘  │
│                                             │           │
│                                      SSM Endpoint       │
│                                      (no SSH needed)    │
└─────────────────────────────────────────────────────────┘

Ansible Control Node (local or EC2)
       │
       ├── SSH ──────► DEV instances
       ├── SSH ──────► QA instances
       └── SSM ──────► PROD instances (private subnet, no public IP)
```

---

## Pre-requisites

- AWS account with IAM permissions for EC2, SSM, and VPC
- Ansible 2.14+ installed on your control node
- Python 3.9+ and `boto3` library (`pip install boto3`)
- AWS CLI configured (`aws configure`)
- SSH key pair created in AWS

```bash
# Install required Ansible collections
ansible-galaxy collection install amazon.aws
ansible-galaxy collection install community.general
```

---

## Environment Setup

### Step 1 — Launch EC2 Instances

Launch 2 instances per environment (RHEL 9 + Amazon Linux 2023):

```bash
# DEV instances (public subnet, SSH accessible)
aws ec2 run-instances \
  --image-id ami-0583d8c7a9c35822c \   # RHEL 9 in us-east-1
  --instance-type t3.micro \
  --key-name my-keypair \
  --subnet-id subnet-dev-xxxxxx \
  --security-group-ids sg-dev-xxxxxx \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Env,Value=DEV},{Key=OS,Value=rhel9},{Key=PatchGroup,Value=DEV-Linux}]' \
  --count 1

# Repeat for Amazon Linux 2023 (different AMI)
aws ec2 run-instances \
  --image-id ami-0ebfd941bbafe70c6 \   # Amazon Linux 2023 in us-east-1
  --instance-type t3.micro \
  --key-name my-keypair \
  --subnet-id subnet-dev-xxxxxx \
  --security-group-ids sg-dev-xxxxxx \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Env,Value=DEV},{Key=OS,Value=al2023},{Key=PatchGroup,Value=DEV-Linux}]' \
  --count 1
```

Repeat for QA and PROD environments. PROD instances go in the **private subnet** with no public IP.

### Step 2 — Attach IAM Role to All Instances

All instances need an IAM instance profile with this policy attached:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ssm:UpdateInstanceInformation",
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel",
        "s3:GetObject"
      ],
      "Resource": "*"
    }
  ]
}
```

Attach it:

```bash
aws ec2 associate-iam-instance-profile \
  --instance-id i-xxxxxxxxxxxxxxxxx \
  --iam-instance-profile Name=SSM-EC2-InstanceProfile
```

### Step 3 — Verify SSM Agent is Running

```bash
# On each instance (via SSH for DEV/QA, SSM Session Manager for PROD)
sudo systemctl status amazon-ssm-agent

# If not running:
sudo systemctl enable --now amazon-ssm-agent

# Verify instance shows up in SSM
aws ssm describe-instance-information --query "InstanceInformationList[*].[InstanceId,PingStatus,PlatformName]" --output table
```

### Step 4 — Build Ansible Inventory

```ini
# inventory/hosts.ini

[dev]
ec2-dev-rhel9    ansible_host=54.x.x.10   ansible_user=ec2-user  ansible_ssh_private_key_file=~/.ssh/my-keypair.pem
ec2-dev-al2023   ansible_host=54.x.x.11   ansible_user=ec2-user  ansible_ssh_private_key_file=~/.ssh/my-keypair.pem

[qa]
ec2-qa-rhel9     ansible_host=54.x.x.20   ansible_user=ec2-user  ansible_ssh_private_key_file=~/.ssh/my-keypair.pem
ec2-qa-al2023    ansible_host=54.x.x.21   ansible_user=ec2-user  ansible_ssh_private_key_file=~/.ssh/my-keypair.pem

[prod]
ec2-prod-rhel9   ansible_host=10.0.3.10   ansible_connection=aws_ssm  ansible_aws_ssm_instance_id=i-xxxxxxxxxx  ansible_aws_ssm_region=us-east-1
ec2-prod-al2023  ansible_host=10.0.3.11   ansible_connection=aws_ssm  ansible_aws_ssm_instance_id=i-yyyyyyyyyy  ansible_aws_ssm_region=us-east-1

[all:vars]
ansible_python_interpreter=/usr/bin/python3
```

---

## Project Structure

```
ansible-aws-ec2-patch-compliance/
│
├── README.md
├── ansible.cfg
├── inventory/
│   └── hosts.ini
│
├── group_vars/
│   ├── all.yml               # shared variables
│   ├── dev.yml               # DEV-specific overrides
│   ├── qa.yml                # QA-specific overrides
│   └── prod.yml              # PROD-specific overrides
│
├── roles/
│   ├── pre-patch/            # pre-patch checks and snapshots
│   ├── patching/             # core yum/dnf update logic
│   ├── post-patch/           # health checks after reboot
│   └── cis-hardening/        # CIS benchmark controls
│
├── playbooks/
│   ├── patch-dev.yml
│   ├── patch-qa.yml
│   ├── patch-prod.yml
│   └── health-check.yml
│
├── scripts/
│   └── post-patch-check.sh
│
└── logs/
    └── patch-report-YYYY-MM-DD.log
```

---

## How the Patch Cycle Works

### The Monthly Patch Calendar

```
Week 1 (Monday)   → Patch DEV
Week 2 (Monday)   → Patch QA   (after DEV is validated)
Week 3 (Saturday) → Patch PROD (maintenance window, off-peak)
Week 4            → Compliance validation + report
```

### Why This Order Matters

If a kernel update breaks a service (e.g., a new kernel ABI breaks the CrowdStrike sensor or a custom kernel module), it gets caught in DEV first — before it reaches PROD and causes a customer-facing outage.

### Pre-Patch Checklist (automated via Ansible)

Before any patching begins, the `pre-patch` role:

1. Takes an EBS snapshot of the root volume (safety net for rollback)
2. Records the current kernel version (`uname -r`)
3. Checks disk space — fails if any filesystem is over 80%
4. Verifies critical services are running (sets a baseline)
5. Saves the list of currently installed packages (`rpm -qa > /tmp/pre-patch-packages.txt`)

---

## Ansible Roles

### Role: pre-patch

```yaml
# roles/pre-patch/tasks/main.yml

- name: record pre-patch kernel version
  command: uname -r
  register: pre_kernel
  changed_when: false

- name: save pre-patch kernel to file
  copy:
    content: "{{ pre_kernel.stdout }}"
    dest: /tmp/pre-patch-kernel.txt

- name: check disk space before patching
  assert:
    that:
      - item.size_available > item.size_total * 0.20
    fail_msg: "Insufficient disk space on {{ item.mount }} — aborting patch."
  loop: "{{ ansible_mounts }}"
  when: item.mount in ['/', '/var', '/tmp']

- name: snapshot installed packages
  shell: rpm -qa --queryformat '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort > /tmp/pre-patch-packages.txt
  changed_when: false

- name: verify critical services are running before patch
  service_facts:

- name: assert services are active pre-patch
  assert:
    that:
      - ansible_facts.services[item + '.service'] is defined
      - ansible_facts.services[item + '.service'].state == 'running'
    fail_msg: "{{ item }} is NOT running before patch — investigate before proceeding."
  loop: "{{ critical_services }}"
```

```yaml
# group_vars/all.yml
critical_services:
  - sshd
  - amazon-ssm-agent
  - crond
```

---

### Role: patching

```yaml
# roles/patching/tasks/main.yml

- name: patch RHEL/CentOS systems
  yum:
    name: "*"
    state: latest
    security: "{{ security_only | default(false) }}"
    exclude: "{{ patch_exclude_packages | default([]) }}"
  when: ansible_os_family == "RedHat" and ansible_distribution_major_version | int <= 7
  notify: reboot if required

- name: patch RHEL 8+ / Amazon Linux 2023 systems
  dnf:
    name: "*"
    state: latest
    security: "{{ security_only | default(false) }}"
    exclude: "{{ patch_exclude_packages | default([]) }}"
  when: ansible_os_family == "RedHat" and ansible_distribution_major_version | int >= 8
  notify: reboot if required

- name: check if reboot is required
  command: needs-restarting -r
  register: reboot_required
  failed_when: false
  changed_when: reboot_required.rc == 1
```

```yaml
# roles/patching/handlers/main.yml

- name: reboot if required
  reboot:
    reboot_timeout: 300
    post_reboot_delay: 30
    test_command: systemctl is-active sshd
  when: reboot_required.rc == 1
```

```yaml
# group_vars/prod.yml — PROD has stricter controls
security_only: false          # full patch in PROD too, but after DEV/QA validation
patch_exclude_packages:
  - kernel-devel              # exclude kernel-devel to prevent accidental rebuilds
reboot_window: "Saturday 02:00-05:00"
```

---

### Role: post-patch

```yaml
# roles/post-patch/tasks/main.yml

- name: wait for system to come back after reboot
  wait_for_connection:
    delay: 15
    timeout: 300

- name: gather service facts post-patch
  service_facts:

- name: assert critical services are running post-patch
  assert:
    that:
      - ansible_facts.services[item + '.service'].state == 'running'
    fail_msg: "ALERT: {{ item }} is DOWN after patching on {{ inventory_hostname }}"
    success_msg: "OK: {{ item }} is running on {{ inventory_hostname }}"
  loop: "{{ critical_services }}"

- name: record post-patch kernel version
  command: uname -r
  register: post_kernel
  changed_when: false

- name: log kernel change
  debug:
    msg: "Kernel updated: {{ lookup('file', '/tmp/pre-patch-kernel.txt') }} → {{ post_kernel.stdout }}"

- name: check disk usage post-patch
  assert:
    that:
      - item.size_available > item.size_total * 0.15
    fail_msg: "WARNING: Low disk space on {{ item.mount }} after patching"
  loop: "{{ ansible_mounts }}"
  when: item.mount in ['/', '/var']

- name: generate patch summary report
  template:
    src: patch-report.j2
    dest: "/tmp/patch-report-{{ ansible_date_time.date }}.txt"

- name: fetch patch report to control node
  fetch:
    src: "/tmp/patch-report-{{ ansible_date_time.date }}.txt"
    dest: "logs/{{ inventory_hostname }}-patch-report-{{ ansible_date_time.date }}.txt"
    flat: yes
```

---

### Role: cis-hardening

Applied after every patch cycle to ensure no update loosened the security posture.

```yaml
# roles/cis-hardening/tasks/main.yml

- name: set kernel parameters (CIS 3.x controls)
  sysctl:
    name: "{{ item.name }}"
    value: "{{ item.value }}"
    state: present
    reload: yes
    sysctl_file: /etc/sysctl.d/99-cis.conf
  loop:
    - { name: "net.ipv4.ip_forward",                    value: "0" }
    - { name: "net.ipv4.conf.all.accept_redirects",     value: "0" }
    - { name: "net.ipv4.conf.all.send_redirects",       value: "0" }
    - { name: "net.ipv4.conf.all.accept_source_route",  value: "0" }
    - { name: "kernel.randomize_va_space",               value: "2" }
    - { name: "fs.suid_dumpable",                        value: "0" }
    - { name: "net.ipv4.tcp_syncookies",                 value: "1" }

- name: configure SSH hardening (CIS 5.2)
  lineinfile:
    path: /etc/ssh/sshd_config
    regexp: "{{ item.regexp }}"
    line: "{{ item.line }}"
    validate: "sshd -t -f %s"
  loop:
    - { regexp: '^#?PermitRootLogin',       line: 'PermitRootLogin no' }
    - { regexp: '^#?PasswordAuthentication', line: 'PasswordAuthentication no' }
    - { regexp: '^#?MaxAuthTries',           line: 'MaxAuthTries 3' }
    - { regexp: '^#?ClientAliveInterval',    line: 'ClientAliveInterval 300' }
    - { regexp: '^#?ClientAliveCountMax',    line: 'ClientAliveCountMax 0' }
    - { regexp: '^#?X11Forwarding',          line: 'X11Forwarding no' }
  notify: restart sshd

- name: set password quality requirements (CIS 5.4)
  lineinfile:
    path: /etc/security/pwquality.conf
    regexp: "{{ item.regexp }}"
    line: "{{ item.line }}"
  loop:
    - { regexp: '^#?minlen',   line: 'minlen = 14' }
    - { regexp: '^#?dcredit',  line: 'dcredit = -1' }
    - { regexp: '^#?ucredit',  line: 'ucredit = -1' }
    - { regexp: '^#?ocredit',  line: 'ocredit = -1' }
    - { regexp: '^#?lcredit',  line: 'lcredit = -1' }

- name: configure account lockout via pam_faillock (CIS 5.4.2)
  lineinfile:
    path: /etc/security/faillock.conf
    regexp: "{{ item.regexp }}"
    line: "{{ item.line }}"
  loop:
    - { regexp: '^#?deny',         line: 'deny = 5' }
    - { regexp: '^#?unlock_time',  line: 'unlock_time = 900' }

- name: disable unused services (CIS 2.x)
  service:
    name: "{{ item }}"
    state: stopped
    enabled: false
  loop:
    - avahi-daemon
    - cups
    - rpcbind
  ignore_errors: true
```

---

## Running the Playbooks

### Patch DEV (Week 1)

```bash
ansible-playbook playbooks/patch-dev.yml -i inventory/hosts.ini -v

# Dry run first (always recommended)
ansible-playbook playbooks/patch-dev.yml -i inventory/hosts.ini --check --diff
```

### Patch QA (Week 2 — after DEV validated)

```bash
ansible-playbook playbooks/patch-qa.yml -i inventory/hosts.ini -v
```

### Patch PROD (Week 3 — maintenance window)

```bash
# PROD patches via SSM — no SSH required
ansible-playbook playbooks/patch-prod.yml -i inventory/hosts.ini -v
```

### Sample playbook (patch-dev.yml)

```yaml
---
- name: DEV Environment — Monthly Patch Cycle
  hosts: dev
  become: yes
  serial: 1                        # patch one host at a time in DEV
  max_fail_percentage: 0           # stop if ANY host fails

  pre_tasks:
    - name: announce patch start
      debug:
        msg: "Starting patch cycle on {{ inventory_hostname }} at {{ ansible_date_time.iso8601 }}"

  roles:
    - role: pre-patch
    - role: patching
    - role: post-patch
    - role: cis-hardening

  post_tasks:
    - name: patch cycle complete
      debug:
        msg: "Patch cycle completed successfully on {{ inventory_hostname }}"
```

---

## Post-Patch Health Checks

The `post-patch-check.sh` script runs independently on each server via cron after a reboot to catch any delayed failures:

```bash
#!/bin/bash
# scripts/post-patch-check.sh
# Runs 10 minutes after reboot via: @reboot sleep 600 && /opt/scripts/post-patch-check.sh

HOSTNAME=$(hostname)
DATE=$(date +%Y-%m-%d)
LOGFILE="/var/log/post-patch-check-${DATE}.log"
ERRORS=0

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOGFILE"
}

check_service() {
  if systemctl is-active --quiet "$1"; then
    log "OK: $1 is running"
  else
    log "FAIL: $1 is NOT running"
    systemctl start "$1"
    ((ERRORS++))
  fi
}

check_disk() {
  df -H | grep -vE '^Filesystem|tmpfs|cdrom' | awk '{print $5 " " $6}' | while read usage mount; do
    val="${usage%\%}"
    if [ "$val" -gt 85 ]; then
      log "WARN: Disk usage on $mount is at ${val}%"
      ((ERRORS++))
    fi
  done
}

log "===== POST-PATCH HEALTH CHECK: $HOSTNAME ====="
log "Kernel: $(uname -r)"

for svc in sshd crond amazon-ssm-agent; do
  check_service "$svc"
done

check_disk

if [ $ERRORS -eq 0 ]; then
  log "RESULT: PASSED — all checks healthy on $HOSTNAME"
else
  log "RESULT: FAILED — $ERRORS issue(s) found on $HOSTNAME"
  # Send to syslog so Splunk/CloudWatch picks it up
  logger -t post-patch-check "PATCH HEALTH FAIL: $ERRORS errors on $HOSTNAME — see $LOGFILE"
fi
```

---

## CIS Hardening

After each patch cycle, CIS Level 1 controls are validated using **OpenSCAP**:

```bash
# Install OpenSCAP
dnf install -y openscap-scanner scap-security-guide

# Run CIS Level 1 scan on RHEL 9
oscap xccdf eval \
  --profile xccdf_org.ssgproject.content_profile_cis_workstation_l1 \
  --results /tmp/oscap-results.xml \
  --report /tmp/oscap-report.html \
  /usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml

# View report
firefox /tmp/oscap-report.html   # or copy to local machine
```

Target: **80%+ compliance score** before promoting patches from QA to PROD.

---

## SSM Patching (No Public IP)

PROD instances sit in a private subnet with no public IP and no internet gateway route. SSH is not possible from outside the VPC. SSM Agent handles all remote access.

### How SSM Session Manager works

```
Ansible Control Node
        │
        │  (HTTPS to SSM endpoint — no inbound ports needed on instance)
        ▼
AWS SSM Service (Regional Endpoint)
        │
        ▼
SSM Agent on EC2 Instance (polls outbound, establishes tunnel)
```

The instance only needs **outbound HTTPS (443)** to the SSM endpoint — no inbound SSH port open.

### Verify connectivity before patching PROD

```bash
# Check instance is reachable via SSM
aws ssm start-session --target i-xxxxxxxxxxxxxxxxx

# Run a quick command without opening a full session
aws ssm send-command \
  --instance-ids "i-xxxxxxxxxxxxxxxxx" \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["uname -r && df -H && systemctl is-active sshd"]' \
  --query "Command.CommandId" \
  --output text
```

---

## Sample Output

```
PLAY [DEV Environment — Monthly Patch Cycle] ***********************************

TASK [pre-patch : record pre-patch kernel version] *****************************
ok: [ec2-dev-rhel9]

TASK [pre-patch : check disk space before patching] ****************************
ok: [ec2-dev-rhel9] => (item={'mount': '/', 'size_available': 8327192576, 'size_total': 10737418240})

TASK [patching : patch RHEL 8+ / Amazon Linux 2023 systems] ********************
changed: [ec2-dev-rhel9]

TASK [patching : check if reboot is required] **********************************
changed: [ec2-dev-rhel9]

RUNNING HANDLER [patching : reboot if required] ********************************
changed: [ec2-dev-rhel9]

TASK [post-patch : wait for system to come back after reboot] ******************
ok: [ec2-dev-rhel9]

TASK [post-patch : assert critical services are running post-patch] *************
ok: [ec2-dev-rhel9] => (item=sshd) => {
    "msg": "OK: sshd is running on ec2-dev-rhel9"
}
ok: [ec2-dev-rhel9] => (item=amazon-ssm-agent) => {
    "msg": "OK: amazon-ssm-agent is running on ec2-dev-rhel9"
}

TASK [post-patch : log kernel change] ******************************************
ok: [ec2-dev-rhel9] => {
    "msg": "Kernel updated: 5.14.0-362.8.1.el9_3.x86_64 → 5.14.0-427.31.1.el9_4.x86_64"
}

PLAY RECAP *********************************************************************
ec2-dev-rhel9              : ok=14  changed=3   unreachable=0  failed=0
ec2-dev-al2023             : ok=14  changed=3   unreachable=0  failed=0
```

---

## Lessons Learned

**1. Always do a dry run first**
Running `--check --diff` before the real patch job catches config file changes and package conflicts without touching the system.

**2. `needs-restarting -r` before rebooting**
Not every patch requires a reboot. Only kernel updates and glibc changes need one. Skipping unnecessary reboots reduces downtime.

**3. Kernel version pinning for third-party agents**
CrowdStrike Falcon sensor and some other kernel-level agents have a supported kernel version list. Patching to an unsupported kernel breaks the agent silently — always check compatibility before PROD patch night.

**4. SSM over SSH for PROD**
Once SSM was in place, there was no reason to open port 22 on PROD instances at all. Removing SSH access from PROD security groups improved the security posture significantly.

**5. `serial: 1` in PROD playbooks**
Patching one host at a time in PROD means if something fails, only one instance is affected. With `max_fail_percentage: 0`, Ansible stops immediately and the rest of the fleet is untouched.

**6. The patch report template matters**
A well-structured patch report (kernel before/after, packages updated, services status) saves hours of post-patch verification calls with app teams and DBAs.

---

## Tech Stack

| Tool | Purpose |
|------|---------|
| Ansible 2.14 | Patch automation, hardening, health checks |
| AWS EC2 | RHEL 9 + Amazon Linux 2023 instances |
| AWS SSM Agent | Agentless access to private subnet instances |
| AWS IAM | Instance profiles for SSM permissions |
| OpenSCAP | CIS benchmark compliance validation |
| Bash | Post-reboot health check script |
| Git | Version control for all playbooks |

---

*Built as a personal lab project to simulate real-world enterprise Linux patch management workflows — 2026*
