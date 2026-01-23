const state = {
  lists: {
    must: {
      backlog: [],
      working: [],
    },
    want: {
      backlog: [],
      working: [],
    },
  },
};

const statusOptions = [
  { value: "active", label: "Active" },
  { value: "waiting", label: "Waiting" },
  { value: "done", label: "Done (remove)" },
];

const listContainers = {
  "must-backlog": document.querySelector('[data-items="must-backlog"]'),
  "must-working": document.querySelector('[data-items="must-working"]'),
  "want-backlog": document.querySelector('[data-items="want-backlog"]'),
  "want-working": document.querySelector('[data-items="want-working"]'),
};

const forms = document.querySelectorAll(".item-form");

const createId = () => `item-${crypto.randomUUID()}`;

const parsePriority = (value) => {
  const parsed = Number.parseInt(value, 10);
  if (Number.isNaN(parsed)) {
    return 1;
  }
  return Math.min(Math.max(parsed, 1), 5);
};

const sortItems = (items) =>
  [...items].sort((a, b) => {
    const aHasDue = Boolean(a.dueDate);
    const bHasDue = Boolean(b.dueDate);

    if (aHasDue !== bHasDue) {
      return aHasDue ? -1 : 1;
    }

    if (b.priority !== a.priority) {
      return b.priority - a.priority;
    }

    if (aHasDue && bHasDue && a.dueDate !== b.dueDate) {
      return new Date(a.dueDate) - new Date(b.dueDate);
    }

    return a.createdAt - b.createdAt;
  });

const getItemCollection = (listKey, location) => state.lists[listKey][location];

const removeItem = (listKey, location, id) => {
  state.lists[listKey][location] = state.lists[listKey][location].filter(
    (item) => item.id !== id
  );
};

const findItem = (id) => {
  const entries = Object.entries(state.lists);
  for (const [listKey, locations] of entries) {
    for (const [locationKey, items] of Object.entries(locations)) {
      const itemIndex = items.findIndex((item) => item.id === id);
      if (itemIndex !== -1) {
        return { item: items[itemIndex], listKey, locationKey, itemIndex };
      }
    }
  }
  return null;
};

const render = () => {
  Object.entries(listContainers).forEach(([zone, container]) => {
    const [listKey, location] = zone.split("-");
    const items = getItemCollection(listKey, location);
    container.innerHTML = "";

    if (items.length === 0) {
      const emptyState = document.createElement("p");
      emptyState.className = "empty";
      emptyState.textContent = "Drop tasks here";
      emptyState.style.color = "#9aa3b2";
      emptyState.style.fontSize = "0.85rem";
      container.appendChild(emptyState);
      return;
    }

    sortItems(items).forEach((item) => {
      container.appendChild(createCard(item));
    });
  });
};

const createCard = (item) => {
  const card = document.createElement("article");
  card.className = "card";
  card.draggable = true;
  card.dataset.id = item.id;

  card.addEventListener("dragstart", handleDragStart);
  card.addEventListener("dragend", handleDragEnd);

  const titleRow = document.createElement("div");
  titleRow.className = "card__title";
  const title = document.createElement("span");
  title.textContent = item.title;
  const priority = document.createElement("span");
  priority.textContent = `P${item.priority}`;
  priority.className = "tag";
  titleRow.append(title, priority);

  const meta = document.createElement("div");
  meta.className = "card__meta";
  const statusTag = document.createElement("span");
  statusTag.className = "tag";
  statusTag.textContent = item.status;
  meta.append(statusTag);

  if (item.dueDate) {
    const dueTag = document.createElement("span");
    dueTag.className = "tag tag--due";
    dueTag.textContent = `Due ${new Date(item.dueDate).toLocaleDateString()}`;
    meta.append(dueTag);
  }

  const statusSelect = document.createElement("select");
  statusSelect.className = "status-select";
  statusOptions.forEach((option) => {
    const opt = document.createElement("option");
    opt.value = option.value;
    opt.textContent = option.label;
    if (option.value === item.status) {
      opt.selected = true;
    }
    statusSelect.appendChild(opt);
  });
  statusSelect.addEventListener("change", (event) => {
    const nextStatus = event.target.value;
    if (nextStatus === "done") {
      const found = findItem(item.id);
      if (found) {
        removeItem(found.listKey, found.locationKey, item.id);
      }
      render();
      return;
    }
    item.status = nextStatus;
    render();
  });

  const subtasks = document.createElement("div");
  subtasks.className = "subtasks";

  const subtasksList = document.createElement("div");
  subtasksList.className = "subtasks__list";
  item.subtasks.forEach((subtask) => {
    const subtaskRow = document.createElement("label");
    subtaskRow.className = "subtask";
    const checkbox = document.createElement("input");
    checkbox.type = "checkbox";
    checkbox.checked = subtask.done;
    checkbox.addEventListener("change", (event) => {
      subtask.done = event.target.checked;
    });
    const text = document.createElement("span");
    text.textContent = subtask.title;
    subtaskRow.append(checkbox, text);
    subtasksList.appendChild(subtaskRow);
  });

  const subtaskForm = document.createElement("form");
  subtaskForm.className = "subtasks__form";
  const subtaskInput = document.createElement("input");
  subtaskInput.type = "text";
  subtaskInput.placeholder = "Add subtask";
  const subtaskButton = document.createElement("button");
  subtaskButton.type = "submit";
  subtaskButton.textContent = "+";
  subtaskForm.append(subtaskInput, subtaskButton);
  subtaskForm.addEventListener("submit", (event) => {
    event.preventDefault();
    const value = subtaskInput.value.trim();
    if (!value) {
      return;
    }
    item.subtasks.push({ title: value, done: false });
    subtaskInput.value = "";
    render();
  });

  subtasks.append(subtasksList, subtaskForm);

  card.append(titleRow, meta, statusSelect, subtasks);

  if (item.status === "active") {
    card.style.borderColor = "#2e7cf6";
  }
  if (item.status === "waiting") {
    card.style.borderColor = "#f6a32e";
  }

  return card;
};

const handleDragStart = (event) => {
  const { id } = event.currentTarget.dataset;
  event.dataTransfer.setData("text/plain", id);
  event.currentTarget.classList.add("dragging");
};

const handleDragEnd = (event) => {
  event.currentTarget.classList.remove("dragging");
};

const handleDrop = (event) => {
  event.preventDefault();
  const id = event.dataTransfer.getData("text/plain");
  const targetZone = event.currentTarget.dataset.dropZone;
  const [listKey, location] = targetZone.split("-");
  const found = findItem(id);
  if (!found) {
    return;
  }
  if (found.listKey === listKey && found.locationKey === location) {
    return;
  }
  removeItem(found.listKey, found.locationKey, id);
  state.lists[listKey][location].push(found.item);
  render();
};

const handleDragOver = (event) => {
  event.preventDefault();
};

const setupDropZones = () => {
  document.querySelectorAll("[data-drop-zone]").forEach((zone) => {
    zone.addEventListener("dragover", handleDragOver);
    zone.addEventListener("drop", handleDrop);
    zone.addEventListener("dragenter", () => zone.classList.add("drag-over"));
    zone.addEventListener("dragleave", () => zone.classList.remove("drag-over"));
    zone.addEventListener("drop", () => zone.classList.remove("drag-over"));
  });
};

forms.forEach((form) => {
  form.addEventListener("submit", (event) => {
    event.preventDefault();
    const formData = new FormData(form);
    const listKey = form.dataset.form;
    const item = {
      id: createId(),
      title: formData.get("title").toString().trim(),
      priority: parsePriority(formData.get("priority")),
      dueDate: formData.get("dueDate")?.toString() || "",
      status: "active",
      subtasks: [],
      createdAt: Date.now(),
    };

    if (!item.title) {
      return;
    }

    state.lists[listKey].backlog.unshift(item);
    form.reset();
    render();
  });
});

setupDropZones();
render();
