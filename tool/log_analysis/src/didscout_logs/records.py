"""Wire models of the buffer and marker files the app writes."""

from typing import Annotated, Literal

from pydantic import AwareDatetime, BaseModel, ConfigDict, Field
from pydantic.alias_generators import to_camel


class _BufferModel(BaseModel):
    model_config = ConfigDict(alias_generator=to_camel, frozen=True)


class BufferHeader(_BufferModel):
    """The first line of a buffer file.

    Attributes:
        format: The buffer format name.
        session_id: The recording session's id.
        created_utc_ms: When the session started, in Unix milliseconds.
    """

    format: str
    session_id: str
    created_utc_ms: int


class ReadRecord(_BufferModel):
    """One read in a buffer file.

    Attributes:
        sequence: The read's position in the session.
        signal_id: `<module id>_<request hex, lower case>`.
        request_started_utc_ms: When the request was sent.
        received_utc_ms: When the reply arrived; absent on failures.
        duration_ns: How long the exchange took.
        raw: Hex of the adapter's ASCII reply.
        transport: `ok` or the transport failure, e.g. `timeout`.
        one_shot: Whether this was a discovery, focus or experiment
            read rather than one of the recurring plan.
    """

    sequence: int
    signal_id: str
    request_started_utc_ms: int
    received_utc_ms: int | None = None
    duration_ns: int
    raw: str
    transport: str
    one_shot: bool = False


class _MarkerModel(BaseModel):
    model_config = ConfigDict(frozen=True)


class ModuleSpec(_MarkerModel):
    """A module's CAN addressing as a plan or modules marker lists it.

    Attributes:
        id: The module id used in signal ids.
        request: The request header.
        response: The response header.
    """

    id: str
    request: str
    response: str


class ModulesMarker(_MarkerModel):
    """A `plan` or `modules` marker listing module addressing.

    Attributes:
        type: `plan` or `modules`.
        modules: The modules listed.
    """

    type: Literal["plan", "modules"]
    modules: list[ModuleSpec]


class ReadingMarker(_MarkerModel):
    """A value the owner read off the vehicle's display.

    Attributes:
        type: Always `reading`.
        quantity: What was read, e.g. `soc`.
        value: The value entered.
        read_at: When the owner looked at the display.
        source: How the value was entered: `typed`, `stepped`,
            `confirmed` or a value a newer app adds.
    """

    type: Literal["reading"]
    quantity: str
    value: float
    read_at: AwareDatetime
    source: str


class ExperimentMarker(_MarkerModel):
    """One step of a guided experiment run.

    Attributes:
        type: Always `experiment`.
        id: The experiment's catalog id.
        step: `before`, `action`, `after`, `undo`, `cancelled` or a
            step a newer app adds.
        at: When the step began.
        reason: Why the run failed, on a `cancelled` step of newer
            apps.
    """

    type: Literal["experiment"]
    id: str
    step: str
    at: AwareDatetime
    reason: str | None = None


type Marker = Annotated[
    ModulesMarker | ReadingMarker | ExperimentMarker, Field(discriminator="type")
]

MARKER_TYPES = frozenset({"plan", "modules", "reading", "experiment"})
