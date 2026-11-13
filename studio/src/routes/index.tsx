import { createFileRoute } from "@tanstack/react-router";
import { Studio } from "@/components/melos/Studio";

export const Route = createFileRoute("/")({ component: Home });

function Home() {
  return <Studio />;
}
