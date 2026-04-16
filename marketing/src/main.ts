import "./style.css";

const io = new IntersectionObserver(
	(entries) => {
		for (const e of entries) {
			if (e.isIntersecting) {
				(e.target as HTMLElement).classList.add("visible");
				io.unobserve(e.target);
			}
		}
	},
	{ threshold: 0.1 },
);

document
	.querySelectorAll("[data-reveal]")
	?.forEach((el) => void io.observe(el));
