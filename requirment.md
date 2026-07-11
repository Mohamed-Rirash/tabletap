Café Management System (PWA Version)

A smart, modern, and mobile-friendly solution to run your café efficiently—accessible on any device with installable PWA features.


---

User Roles

1. Manager


2. Cashier


3. Waiter (via notifications)


4. Customer (via QR menu)




---

System Features (Grouped by Functionality)

1. User & Role Management

Register users with different roles (manager, cashier, waiter)

Activate/deactivate staff accounts

View staff list and roles

Assign tasks or permissions to users



---

2. Menu Management  *(only for manager)*

- Add/edit/delete food & drink items

- Upload images, descriptions, and price

- Mark items available/unavailable daily

- Set maximum quantity (limit per item per day)

- Auto-generate QR codes for tables with that day's menu



---

3. POS System (for Cashiers)

- Visual product selection (images + prices)

- Quantity entry with auto-calculation

- Fast and simple order placement

- Receipts printing

- Search items quickly



---

4. Customer QR Ordering

- Scan table QR code to:

- View current day’s menu

- Select items and quantity

- Make payment via phone

- Order notification goes to the most available waiter

- Waiter scans QR code to confirm correct delivery

- FIFO order queue with timers for transparency



---

5. Inventory Management

- Add ingredients with quantities and units

- Set minimum stock thresholds per item

- Auto-deduct ingredients when items are sold

- View usage history of ingredients

- Add stock to kitchen or storage areas

- Track multi-location stock (optional)



---

6. Inventory Shortage & Reorder Report

- System flags low-stock items

- Auto-generate a restock report

- Item name, current amount, threshold, suggested amount

- Printable/exportable for supplier use



---

7. Reports & Analytics

Sales reports (daily, weekly, monthly, or custom range)

Inventory usage trends

Top-selling menu items

Employee performance (optional phase)

Export reports to PDF or Excel



---

8. Daily Planning for Manager

Set daily dish limits (e.g., “rice for 50 people”)

Control what's available each day

Get real-time updates on what’s sold out



---

9. Notifications System

Order alerts for waiters

Low inventory alerts

Sales summary notifications

Payment or receipt alerts (optional)



---

10. Landing Page

Café intro (name, logo, about)

Today’s menu preview

Opening hours & map

Contact info or WhatsApp link

Optional photo gallery or testimonials



---

11. PWA Features

Installable on phones and tablets

Works offline or in low network areas

Feels like a native app

Push notifications for alerts

No need for App Store or Play Store deployment



---

(Optional Future Phases)

Staff payroll management

Customer loyalty program

Table booking via mobile

WhatsApp or SMS reminders for pre-orders



---

Let me know if you want me to turn this into a proposal PDF or plan out the development phases. Ready when you are!

# Product Requirements Document (PRD)

## 1. Project Overview

### 1.1 Introduction
This document outlines the full requirements for developing a **Modern Cafe Management System** that provides seamless user experience for both customers and staff. The system allows users to scan a table-specific QR code to browse the dynamic daily menu, place orders, and make payments. It also handles inventory, staff, and business analytics efficiently.

### 1.2 Purpose
The purpose of this system is to:
- Digitize and streamline cafe operations.
- Improve customer experience.
- Provide real-time business intelligence.
- Manage staff, sales, inventory, and orders efficiently.

### 1.3 Goals and Objectives
- Enable customers to place and pay for orders from their mobile devices.
- Reduce manual labor and order delays.
- Provide managers with reports and insights into business performance.
- Maintain optimal stock levels through intelligent inventory tracking.

### 1.4 Target Audience
- **Cafe Managers/Owners**: for overall monitoring and decision making.
- **Staff (Waiters, Cashiers)**: for order processing and delivery.
- **Customers**: for seamless ordering and payment.


## 2. Core Functionality

### 2.1 Key Features
- User Registration and Role Management (Admin, Manager, Waiter, Cashier, Customer)
- QR Code Menu Browsing and Ordering
- FIFO-based Waiter Assignment
- Cart Management and Payments
- Inventory Management with Low-Stock Notifications
- Daily, Weekly, Monthly Reports (Sales, Inventory, Staff, Top Selling Items)
- Push Notifications and Timers
- Responsive PWA (Progressive Web App)

### 2.2 User Stories
#### Customer
- As a customer, I want to scan a QR code to see the menu.
- As a customer, I want to add items to a cart and pay directly.
- As a customer, I want to track order progress and estimated delivery.

#### Waiter
- As a waiter, I want to receive and confirm new orders.
- As a waiter, I want to scan QR codes to confirm delivery.

#### Manager
- As a manager, I want to see inventory levels and receive shortage alerts.
- As a manager, I want to assign, activate or deactivate employees.
- As a manager, I want to generate daily/weekly/monthly reports.

#### Cashier
- As a cashier, I want to process in-person payments.
- As a cashier, I want to view sales history.

### 2.3 Use Cases
- **Ordering Flow**:
  1. Customer scans QR code (table-specific).
  2. Daily menu loads dynamically.
  3. Customer selects items, adds to cart, and pays.
  4. Order assigned to available waiter (FIFO).
  5. Waiter receives notification.
  6. Order delivered and confirmed via QR scan.

- **Inventory Management**:
  - Ingredient usage calculated based on order data.
  - Alerts triggered for low-stock levels.
  - Inventory restock report generated.

- **Reporting**:
  - Real-time analytics on sales and usage.
  - Exportable reports (PDF, Excel).


## 3. Technical Requirements

### 3.1 Tech Stack
- **Frontend**: Next.js (TypeScript)
- **Backend**: FastAPI (Python)
- **Database**: PostgreSQL
- **Authentication**: JWT + OAuth2
- **Queue System**: Redis + Celery (for FIFO waiter assignment)
- **Push Notifications**: Firebase Cloud Messaging

### 3.2 Recommended Libraries
#### Frontend
- TailwindCSS
- React Query / TanStack Query
- Zustand or Redux (state management)
- QR code scanner libraries (e.g., `react-qr-reader`)

#### Backend
- SQLAlchemy (ORM)
- Pydantic (validation)
- FastAPI BackgroundTasks
- Redis (queueing)
- APScheduler (for daily reports)

### 3.3 Architecture
- Microservices-ready modular FastAPI backend
- Next.js SSR frontend with PWA enabled
- RESTful API with optional WebSocket updates

### 3.4 File Structure
```
/backend
  ├── app/
  │   ├── api/
  │   ├── core/
  │   ├── models/
  │   ├── schemas/
  │   ├── services/
  │   └── utils/
  ├── tests/
  └── main.py

/frontend
  ├── components/
  ├── pages/
  ├── public/
  ├── services/
  ├── store/
  └── utils/
```


## 4. Documentation

### 4.1 Key Documents
- API Documentation (Swagger via FastAPI)
- Architecture Diagram (System Flow)
- User Role and Permission Map
- Data Models and Relationships (ER Diagram)

### 4.2 Console Script Examples
```bash
# Run daily inventory report generator
$ python manage.py generate_inventory_report

# Run daily sales summary (cron job)
$ python manage.py summarize_sales

# Reset FIFO waiter queue manually
$ python manage.py reset_waiter_queue
```

### 4.3 Integration Examples
```python
# Send notification to waiter (Firebase)
from firebase_admin import messaging

message = messaging.Message(
    notification=messaging.Notification(
        title="New Order",
        body="You have a new order to serve."
    ),
    topic="waiters"
)
messaging.send(message)
```


## 5. Additional Requirements
## 5.1 Performance
- Optimize image and data loading for mobile
- Cache menu items locally (PWA)

### 5.2 Compatibility
- Fully responsive design for mobile/tablet/desktop
- Cross-browser support (Chrome, Safari, Firefox)

### 5.3 Security
- JWT-based authentication
- Role-based access control (RBAC)
- HTTPS enforced
- Input sanitization and validation

### 5.4 Accessibility
- ARIA attributes for screen readers
- High contrast UI mode
- Keyboard navigation enabled
---
Great! Let's break down the requirements into categories to guide both design and development. These requirements cover everything from system functionalities to user roles and technical needs.


---

# Requirements List

1. User Roles & Access

- [ ] Customer can browse menu, place orders, and pay.

- [ ] Waiter can receive assigned orders and confirm delivery.

- [ ] Cashier can accept manual orders and handle POS payments.

- [ ] Manager can:

- Add/update/remove users.

- Assign or deactivate employees.

- Set daily dish limits.

- View all reports (sales, inventory, performance).




---

2. Menu Management

[ ] Dynamic daily menu management.

[ ] Categories, descriptions, prices, and food images.

[ ] QR Code generated for each table linking to the menu.

[ ] Availability toggling for each menu item.



---

3. Ordering System

[ ] Customer scans QR code tied to a table.

[ ] Adds items to cart and pays online.

[ ] FIFO algorithm assigns available waiter.

[ ] Waiter gets notification.

[ ] Waiter delivers and confirms via QR scan.



---

4. Inventory Management

[ ] Track inventory by ingredients.

[ ] Deduct ingredients based on order volume.

[ ] Generate low-stock reports.

[ ] Print/export shortage lists for restocking.



---

5. Sales & Business Reports

[ ] Daily/weekly/monthly sales report.

[ ] Top-selling item reports.

[ ] Export to PDF/Excel.

[ ] Graphs and summaries viewable by the manager.



---

6. Staff Management

[ ] Staff role assignment (cashier, waiter, kitchen, etc.).

[ ] Attendance and activity logs.

[ ] Manager can deactivate or remove staff.

[ ] Optionally integrate payment/bonus tracking.



---

7. Notification System

[ ] Real-time notifications to waiters.

[ ] Timer display for customers after order.

[ ] Alerts for low inventory or completed orders.



---

8. System Infrastructure

[ ] Progressive Web App (PWA) support.

[ ] Secure login with JWT and OAuth2.

[ ] Role-based access control.

[ ] FIFO queuing system using Redis.

[ ] Scheduled reports with APScheduler.



---

9. Administrative Scripts

[ ] Generate daily reports manually or via cron job.

[ ] Reset waiter queues.

[ ] Manual inventory adjustments.



---

10. Optional Add-ons / Future Features

[ ] Landing page for the cafe (marketing).

[ ] Mobile app packaging for offline use.

[ ] Loyalty point system.

[ ] Multi-branch support (chain management).



---
# Functional Requirements

1. Customer Module

Scan QR code to access table-specific menu

View and filter daily menu

Add items to cart and checkout

Track order status (timer + confirmation)


2. Waiter Module

Receive and confirm orders (FIFO)

Scan QR to confirm delivery


3. Cashier Module

Manual POS system for walk-in customers

Handle multiple item entries per order

View transaction history


4. Manager/Admin Module

User account management (add, update, deactivate staff)

Inventory management and thresholds

Report generation: sales, inventory, top selling

Menu planning and availability controls


5. Inventory Module

Track inventory usage based on sales

Low-stock alert system

Generate order lists for suppliers


6. Notifications Module

Real-time order and delivery alerts (Firebase)

Timer countdown for orders



---

Non-Functional Requirements

Role-based access control (RBAC)

Secure authentication and session management

Cross-platform responsive interface (PWA)

RESTful API with potential WebSocket support

Accessible UI (ARIA, keyboard nav, contrast modes)

Performance: fast load times and smooth transitions

